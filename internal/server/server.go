package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/nwalker85/kvasir/internal/orchestrator"
	"github.com/nwalker85/kvasir/internal/types"
)

type Server struct {
	orch *orchestrator.Orchestrator
	mux  *http.ServeMux
}

func New(orch *orchestrator.Orchestrator) *Server {
	s := &Server{
		orch: orch,
		mux:  http.NewServeMux(),
	}
	s.routes()
	return s
}

func (s *Server) routes() {
	s.mux.HandleFunc("/healthz", s.handleHealthz)
	s.mux.HandleFunc("/v1/enroll/host", s.handleEnrollHost)
	s.mux.HandleFunc("/v1/enroll/user", s.handleEnrollUser)
	s.mux.HandleFunc("/v1/receipts/", s.handleGetReceipt)
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":  "ok",
		"service": "kvasir-api",
		"version": "v0.1.0",
	})
}

func (s *Server) handleEnrollHost(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req types.HostEnrollRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	if req.Hostname == "" {
		writeError(w, http.StatusBadRequest, "hostname is required")
		return
	}
	if req.Scope == "" {
		writeError(w, http.StatusBadRequest, "scope is required")
		return
	}

	receipt, err := s.orch.EnrollHost(r.Context(), req)
	if err != nil {
		if errors.Is(err, types.ErrInvalidScope) {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, receipt)
}

func (s *Server) handleEnrollUser(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req types.UserEnrollRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	if req.Username == "" || req.Email == "" || req.Scope == "" {
		writeError(w, http.StatusBadRequest, "username, email, and scope are required")
		return
	}

	receipt, err := s.orch.EnrollUser(r.Context(), req)
	if err != nil {
		if errors.Is(err, types.ErrInvalidScope) {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, receipt)
}

func (s *Server) handleGetReceipt(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	id := strings.TrimPrefix(r.URL.Path, "/v1/receipts/")
	if id == "" {
		writeError(w, http.StatusBadRequest, "receipt id is required")
		return
	}

	receipt, err := s.orch.GetReceipt(id)
	if err != nil {
		if errors.Is(err, types.ErrReceiptNotFound) {
			writeError(w, http.StatusNotFound, "receipt not found")
			return
		}
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, receipt)
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
