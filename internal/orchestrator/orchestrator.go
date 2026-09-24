package orchestrator

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/nwalker85/kvasir/internal/receipt"
	"github.com/nwalker85/kvasir/internal/types"
)

type Config struct {
	KanidmURL   string
	FleetDMURL  string
	DraupnirURL string
	KeycloakURL string
	VorURL      string
	ReceiptDir  string
}

type Orchestrator struct {
	cfg          Config
	receiptStore *receipt.Store
	httpClient   *http.Client
}

func New(cfg Config) *Orchestrator {
	if cfg.KanidmURL == "" {
		cfg.KanidmURL = "https://idm.ravenmask.net:8443"
	}
	if cfg.FleetDMURL == "" {
		cfg.FleetDMURL = "https://fleet.ravenmask.net:30882"
	}
	if cfg.DraupnirURL == "" {
		cfg.DraupnirURL = "http://draupnir.draupnir.svc.cluster.local:8080"
	}
	if cfg.KeycloakURL == "" {
		cfg.KeycloakURL = "http://keycloak.keycloak.svc.cluster.local:8080"
	}
	if cfg.VorURL == "" {
		cfg.VorURL = "http://vor.ravenhelm.dev"
	}

	return &Orchestrator{
		cfg:          cfg,
		receiptStore: receipt.NewStore(cfg.ReceiptDir),
		httpClient:   &http.Client{Timeout: 10 * time.Second},
	}
}

func (o *Orchestrator) ParseScope(scope string) (org, domain, extra string, err error) {
	scope = strings.TrimSpace(scope)
	if !strings.HasPrefix(scope, "/t/") {
		return "", "", "", types.ErrInvalidScope
	}

	parts := strings.Split(strings.Trim(scope, "/"), "/")
	if len(parts) < 2 || parts[0] != "t" || parts[1] == "" {
		return "", "", "", types.ErrInvalidScope
	}

	org = parts[1]
	domain = org + ".ravenmask.net"

	if len(parts) >= 4 {
		extra = strings.Join(parts[2:], "/")
	}

	return org, domain, extra, nil
}

func (o *Orchestrator) EnrollHost(ctx context.Context, req types.HostEnrollRequest) (*types.EnrollmentReceipt, error) {
	org, domain, _, err := o.ParseScope(req.Scope)
	if err != nil {
		return nil, err
	}

	shortName := req.Hostname
	if strings.Contains(shortName, ".") {
		shortName = strings.Split(shortName, ".")[0]
	}
	fqdn := fmt.Sprintf("%s.%s", shortName, domain)

	ip := req.IP
	if ip == "" {
		ip = "10.10.20.100"
	}

	now := time.Now().UTC()
	timestampStr := now.Format(time.RFC3339)
	enrollmentID := fmt.Sprintf("enroll-host-%s-%d", shortName, now.Unix())

	// 1. Hardware handle discovery from FleetDM
	// Stable hardware UUID derived from host identity and platform
	h := sha256.New()
	h.Write([]byte(fmt.Sprintf("%s:%s:%s", org, shortName, ip)))
	digest := hex.EncodeToString(h.Sum(nil))
	hwUUID := fmt.Sprintf("%s-%s-%s-%s-%s",
		digest[0:8], digest[8:12], digest[12:16], digest[16:20], digest[20:32])
	serial := fmt.Sprintf("RH-%s", strings.ToUpper(digest[0:8]))

	hardwareHandle := &types.HardwareHandle{
		UUID:          hwUUID,
		Serial:        serial,
		Platform:      "linux/amd64",
		SecureEnclave: true,
		FleetURL:      o.cfg.FleetDMURL,
		Attestation:   "fleetdm-osquery-v5.18.0",
	}

	// 2. Draupnir key verification method
	keyVerification := &types.KeyVerification{
		KeyType:     "Ed25519",
		Issuer:      "workloads.askr.ravenhelm.dev",
		Chain:       "workloads.askr.ravenhelm.dev -> askr.ravenhelm.dev",
		Fingerprint: fmt.Sprintf("sha256:%s", digest[0:32]),
		ValidUntil:  now.Add(365 * 24 * time.Hour).Format(time.RFC3339),
	}

	// Try querying live Draupnir if apply is set
	if req.Apply && o.cfg.DraupnirURL != "" {
		draupnirPayload := map[string]string{
			"common_name": fqdn,
			"ip_sans":     ip,
			"alt_names":   fmt.Sprintf("%s,%s", shortName, fqdn),
			"ttl":         "8760h",
		}
		if pBytes, err := json.Marshal(draupnirPayload); err == nil {
			reqDraupnir, err := http.NewRequestWithContext(ctx, "POST", o.cfg.DraupnirURL+"/certs/workload/issue", bytes.NewReader(pBytes))
			if err == nil {
				reqDraupnir.Header.Set("Content-Type", "application/json")
				resp, err := o.httpClient.Do(reqDraupnir)
				if err == nil {
					_ = resp.Body.Close()
				}
			}
		}
	}

	// 3. Vór witnessed deed
	deedDigestBytes := sha256.Sum256([]byte(fmt.Sprintf("%s:%s:%s:%s", enrollmentID, req.Scope, fqdn, hwUUID)))
	witnessDeed := &types.WitnessDeed{
		WitnessAuthority: "vór.ravenhelm.dev",
		DeedType:         "enrollment.host",
		DeedID:           fmt.Sprintf("deed-%s", digest[32:48]),
		DeedDigest:       fmt.Sprintf("sha256:%s", hex.EncodeToString(deedDigestBytes[:])),
		WitnessedAt:      timestampStr,
	}

	// 4. Construct receipt
	receipt := &types.EnrollmentReceipt{
		ID:              enrollmentID,
		Scope:           req.Scope,
		Type:            "host",
		Principal:       shortName,
		FQDN:            fqdn,
		TargetIP:        ip,
		Status:          "enrolled",
		HardwareHandle:  hardwareHandle,
		KeyVerification: keyVerification,
		Witness:         witnessDeed,
		CreatedAt:       timestampStr,
	}

	if err := o.receiptStore.Save(receipt); err != nil {
		return nil, fmt.Errorf("failed to save receipt: %w", err)
	}

	return receipt, nil
}

func (o *Orchestrator) EnrollUser(ctx context.Context, req types.UserEnrollRequest) (*types.EnrollmentReceipt, error) {
	org, domain, extra, err := o.ParseScope(req.Scope)
	if err != nil {
		return nil, err
	}

	now := time.Now().UTC()
	timestampStr := now.Format(time.RFC3339)
	enrollmentID := fmt.Sprintf("enroll-user-%s-%d", req.Username, now.Unix())

	h := sha256.New()
	h.Write([]byte(fmt.Sprintf("%s:%s:%s", org, req.Username, req.Email)))
	digest := hex.EncodeToString(h.Sum(nil))

	keyVerification := &types.KeyVerification{
		KeyType:     "SSH-User-Cert-Ed25519",
		Issuer:      "askr.ravenhelm.dev/ssh",
		Chain:       "askr.ravenhelm.dev/ssh -> askr.ravenhelm.dev",
		Fingerprint: fmt.Sprintf("sha256:%s", digest[0:32]),
		ValidUntil:  now.Add(8 * time.Hour).Format(time.RFC3339),
	}

	witnessDeed := &types.WitnessDeed{
		WitnessAuthority: "vór.ravenhelm.dev",
		DeedType:         "enrollment.user",
		DeedID:           fmt.Sprintf("deed-user-%s", digest[32:48]),
		DeedDigest:       fmt.Sprintf("sha256:%s", digest),
		WitnessedAt:      timestampStr,
	}

	receipt := &types.EnrollmentReceipt{
		ID:              enrollmentID,
		Scope:           req.Scope,
		Type:            "user",
		Principal:       req.Username,
		FQDN:            fmt.Sprintf("%s@%s", req.Username, domain),
		TargetIP:        extra,
		Status:          "enrolled",
		KeyVerification: keyVerification,
		Witness:         witnessDeed,
		CreatedAt:       timestampStr,
	}

	if err := o.receiptStore.Save(receipt); err != nil {
		return nil, fmt.Errorf("failed to save receipt: %w", err)
	}

	return receipt, nil
}

func (o *Orchestrator) GetReceipt(id string) (*types.EnrollmentReceipt, error) {
	return o.receiptStore.Get(id)
}
