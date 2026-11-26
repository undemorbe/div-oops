package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// Тесты HTTP-слоя без БД: проверяем только те ветки, которые завершаются до обращения к базе.
func TestMain(m *testing.M) {
	gin.SetMode(gin.TestMode)
	InitLogger()
	os.Exit(m.Run())
}

func newTestRouter() *gin.Engine {
	return NewRouter(NewHandler(nil), "test-instance", "5040")
}

func doRequest(r *gin.Engine, method, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func TestHealth(t *testing.T) {
	w := doRequest(newTestRouter(), http.MethodGet, "/health", "")

	if w.Code != http.StatusOK {
		t.Fatalf("GET /health: ожидали 200, получили %d", w.Code)
	}
}

func TestWhoAmI(t *testing.T) {
	w := doRequest(newTestRouter(), http.MethodGet, "/api/whoami", "")

	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/whoami: ожидали 200, получили %d", w.Code)
	}
	if got := w.Header().Get("X-Instance-Id"); got != "test-instance" {
		t.Errorf("X-Instance-Id: ожидали test-instance, получили %q", got)
	}

	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("ответ не JSON: %v", err)
	}
	if body["instance"] != "test-instance" || body["port"] != "5040" {
		t.Errorf("неожиданный ответ: %v", body)
	}
}

func TestPostTaskRejectsEmptyTitle(t *testing.T) {
	w := doRequest(newTestRouter(), http.MethodPost, "/api/task", `{"task":{"title":""}}`)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("POST /api/task с пустым title: ожидали 400, получили %d", w.Code)
	}
}

func TestPostTaskRejectsInvalidJSON(t *testing.T) {
	w := doRequest(newTestRouter(), http.MethodPost, "/api/task", `{"task":`)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("POST /api/task с битым JSON: ожидали 400, получили %d", w.Code)
	}
}
