package server_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/nwalker85/kvasir/internal/orchestrator"
	"github.com/nwalker85/kvasir/internal/server"
	"github.com/nwalker85/kvasir/internal/types"
)

func setupTestServer(t *testing.T) *server.Server {
	t.Helper()
	tmpDir := t.TempDir()
	cfg := orchestrator.Config{
		ReceiptDir: tmpDir,
	}
	orch := orchestrator.New(cfg)
	return server.New(orch)
}

func TestHealthz(t *testing.T) {
	srv := setupTestServer(t)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()

	srv.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", w.Code)
	}

	var resp map[string]interface{}
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if resp["status"] != "ok" {
		t.Errorf("expected status 'ok', got %v", resp["status"])
	}
	if resp["service"] != "kvasir-api" {
		t.Errorf("expected service 'kvasir-api', got %v", resp["service"])
	}
}

func TestEnrollHostSuccess(t *testing.T) {
	srv := setupTestServer(t)

	body := types.HostEnrollRequest{
		Hostname: "test-node-01",
		Scope:    "/t/ravenmask",
		IP:       "10.10.20.150",
		Apply:    false,
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/v1/enroll/host", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	srv.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", w.Code, w.Body.String())
	}

	var receipt types.EnrollmentReceipt
	if err := json.NewDecoder(w.Body).Decode(&receipt); err != nil {
		t.Fatalf("failed to decode receipt: %v", err)
	}

	if receipt.Scope != "/t/ravenmask" {
		t.Errorf("expected scope /t/ravenmask, got %s", receipt.Scope)
	}
	if receipt.Principal != "test-node-01" {
		t.Errorf("expected principal test-node-01, got %s", receipt.Principal)
	}
	if receipt.Status != "enrolled" {
		t.Errorf("expected status enrolled, got %s", receipt.Status)
	}
	if receipt.HardwareHandle == nil {
		t.Fatal("expected hardware handle, got nil")
	}
	if receipt.HardwareHandle.UUID == "" {
		t.Error("expected non-empty hardware UUID")
	}
	if receipt.HardwareHandle.Serial == "" {
		t.Error("expected non-empty hardware serial")
	}
	if !receipt.HardwareHandle.SecureEnclave {
		t.Error("expected SecureEnclave: true")
	}
	if receipt.KeyVerification == nil {
		t.Fatal("expected key verification, got nil")
	}
	if receipt.KeyVerification.Issuer != "workloads.askr.ravenhelm.dev" {
		t.Errorf("unexpected issuer: %s", receipt.KeyVerification.Issuer)
	}
	if receipt.Witness == nil {
		t.Fatal("expected witness deed, got nil")
	}
	if receipt.Witness.WitnessAuthority != "vór.ravenhelm.dev" {
		t.Errorf("unexpected witness authority: %s", receipt.Witness.WitnessAuthority)
	}

	// Verify retrieval via GET /v1/receipts/{id}
	getReq := httptest.NewRequest(http.MethodGet, "/v1/receipts/"+receipt.ID, nil)
	getW := httptest.NewRecorder()
	srv.ServeHTTP(getW, getReq)

	if getW.Code != http.StatusOK {
		t.Fatalf("expected GET status 200, got %d", getW.Code)
	}
}

func TestEnrollHostInvalidScope(t *testing.T) {
	srv := setupTestServer(t)

	body := types.HostEnrollRequest{
		Hostname: "bad-host",
		Scope:    "invalid-scope",
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/v1/enroll/host", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	srv.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected status 400, got %d", w.Code)
	}
}

func TestEnrollUser(t *testing.T) {
	srv := setupTestServer(t)

	body := types.UserEnrollRequest{
		Username:  "bob",
		Email:     "bob@ravenmask.net",
		Scope:     "/t/ravenmask/g/platform",
		FirstName: "Bob",
		LastName:  "Vance",
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/v1/enroll/user", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	srv.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", w.Code, w.Body.String())
	}

	var receipt types.EnrollmentReceipt
	if err := json.NewDecoder(w.Body).Decode(&receipt); err != nil {
		t.Fatalf("failed to decode receipt: %v", err)
	}

	if receipt.Scope != "/t/ravenmask/g/platform" {
		t.Errorf("unexpected scope: %s", receipt.Scope)
	}
	if receipt.Principal != "bob" {
		t.Errorf("unexpected principal: %s", receipt.Principal)
	}
	if receipt.Type != "user" {
		t.Errorf("unexpected type: %s", receipt.Type)
	}
}
