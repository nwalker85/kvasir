package types

import "errors"

var (
	ErrInvalidScope   = errors.New("invalid scope: must follow ADR-0006 hierarchy starting with /t/{org}")
	ErrForbiddenKey   = errors.New("receipt contains forbidden secret-bearing key")
	ErrReceiptNotFound = errors.New("receipt not found")
)

type HostEnrollRequest struct {
	Hostname string `json:"hostname"`
	Scope    string `json:"scope"`
	IP       string `json:"ip,omitempty"`
	Apply    bool   `json:"apply,omitempty"`
}

type UserEnrollRequest struct {
	Username  string `json:"username"`
	Email     string `json:"email"`
	Scope     string `json:"scope"`
	FirstName string `json:"first_name,omitempty"`
	LastName  string `json:"last_name,omitempty"`
	Apply     bool   `json:"apply,omitempty"`
}

type HardwareHandle struct {
	UUID          string `json:"uuid"`
	Serial        string `json:"serial"`
	Platform      string `json:"platform"`
	SecureEnclave bool   `json:"secure_enclave"`
	FleetURL      string `json:"fleet_url"`
	Attestation   string `json:"attestation,omitempty"`
}

type KeyVerification struct {
	KeyType     string `json:"key_type"`
	Issuer      string `json:"issuer"`
	Chain       string `json:"chain"`
	Fingerprint string `json:"fingerprint"`
	ValidUntil  string `json:"valid_until"`
}

type WitnessDeed struct {
	WitnessAuthority string `json:"witness_authority"`
	DeedType         string `json:"deed_type"`
	DeedID           string `json:"deed_id"`
	DeedDigest       string `json:"deed_digest"`
	WitnessedAt      string `json:"witnessed_at"`
}

type EnrollmentReceipt struct {
	ID              string           `json:"id"`
	Scope           string           `json:"scope"`
	Type            string           `json:"type"`
	Principal       string           `json:"principal"`
	FQDN            string           `json:"fqdn,omitempty"`
	TargetIP        string           `json:"target_ip,omitempty"`
	Status          string           `json:"status"`
	HardwareHandle  *HardwareHandle  `json:"hardware_handle,omitempty"`
	KeyVerification *KeyVerification `json:"key_verification,omitempty"`
	Witness         *WitnessDeed     `json:"witness,omitempty"`
	CreatedAt       string           `json:"created_at"`
}
