package receipt

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sync"

	"github.com/nwalker85/kvasir/internal/types"
)

var forbiddenKeyPattern = regexp.MustCompile(`(?i)(password|token|keytab|private_key|credential|secret|join_token)`)

type Store struct {
	baseDir string
	mu      sync.RWMutex
	memory  map[string]*types.EnrollmentReceipt
}

func NewStore(dir string) *Store {
	if dir == "" {
		dir = "/var/lib/kvasir/receipts"
	}
	_ = os.MkdirAll(dir, 0755)
	return &Store{
		baseDir: dir,
		memory:  make(map[string]*types.EnrollmentReceipt),
	}
}

func AssertSafeReceipt(r *types.EnrollmentReceipt) error {
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}

	var m map[string]interface{}
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}

	return scanKeys(m)
}

func scanKeys(obj interface{}) error {
	switch val := obj.(type) {
	case map[string]interface{}:
		for k, v := range val {
			if forbiddenKeyPattern.MatchString(k) {
				return fmt.Errorf("%w: key %q", types.ErrForbiddenKey, k)
			}
			if err := scanKeys(v); err != nil {
				return err
			}
		}
	case []interface{}:
		for _, item := range val {
			if err := scanKeys(item); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Store) Save(r *types.EnrollmentReceipt) error {
	if err := AssertSafeReceipt(r); err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	s.memory[r.ID] = r

	if s.baseDir != "" {
		path := filepath.Join(s.baseDir, r.ID+".json")
		data, err := json.MarshalIndent(r, "", "  ")
		if err == nil {
			_ = os.WriteFile(path, data, 0644)
		}
	}

	return nil
}

func (s *Store) Get(id string) (*types.EnrollmentReceipt, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if r, ok := s.memory[id]; ok {
		return r, nil
	}

	if s.baseDir != "" {
		path := filepath.Join(s.baseDir, id+".json")
		data, err := os.ReadFile(path)
		if err == nil {
			var r types.EnrollmentReceipt
			if err := json.Unmarshal(data, &r); err == nil {
				if err := AssertSafeReceipt(&r); err == nil {
					return &r, nil
				}
			}
		}
	}

	return nil, types.ErrReceiptNotFound
}
