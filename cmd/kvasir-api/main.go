package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nwalker85/kvasir/internal/orchestrator"
	"github.com/nwalker85/kvasir/internal/server"
)

func main() {
	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":8080"
	}

	cfg := orchestrator.Config{
		KanidmURL:   os.Getenv("KANIDM_URL"),
		FleetDMURL:  os.Getenv("FLEETDM_URL"),
		DraupnirURL: os.Getenv("DRAUPNIR_URL"),
		KeycloakURL: os.Getenv("KEYCLOAK_URL"),
		VorURL:      os.Getenv("VOR_URL"),
		ReceiptDir:  os.Getenv("RECEIPT_DIR"),
	}

	orch := orchestrator.New(cfg)
	srvHandler := server.New(orch)

	httpServer := &http.Server{
		Addr:         listenAddr,
		Handler:      srvHandler,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Printf("kvasir-api starting on %s", listenAddr)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigChan
	log.Printf("received signal %v, shutting down...", sig)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := httpServer.Shutdown(ctx); err != nil {
		log.Printf("shutdown error: %v", err)
	}
	log.Printf("kvasir-api exited cleanly")
}
