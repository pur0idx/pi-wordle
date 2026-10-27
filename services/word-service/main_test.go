package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func testServer() *server {
	loc, _ := time.LoadLocation("Asia/Bangkok")
	s := newServer([]string{"crane", "slate", "pilot"}, []string{"zebus"}, "test-secret", loc, 1)
	s.now = func() time.Time { return time.Date(2026, 11, 17, 12, 0, 0, 0, loc) }
	return s
}

func get(t *testing.T, s *server, path string) (int, map[string]any) {
	t.Helper()
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("%s: bad json %q", path, rec.Body.String())
	}
	return rec.Code, body
}

func TestAnswerIsDeterministicAcrossReplicas(t *testing.T) {
	a, b := testServer(), testServer()
	for _, id := range []string{"2026-11-16", "2026-11-17", "2026-01-01"} {
		if a.answerFor(id) != b.answerFor(id) {
			t.Fatalf("replicas disagree on %s", id)
		}
	}
}

func TestAnswerDependsOnSecret(t *testing.T) {
	loc, _ := time.LoadLocation("Asia/Bangkok")
	words := []string{"aaaaa", "bbbbb", "ccccc", "ddddd", "eeeee", "fffff", "ggggg", "hhhhh"}
	a := newServer(words, nil, "one", loc, 1)
	b := newServer(words, nil, "two", loc, 1)
	differs := false
	for d := 1; d <= 28; d++ {
		id := time.Date(2026, 2, d, 0, 0, 0, 0, loc).Format("2006-01-02")
		if a.answerFor(id) != b.answerFor(id) {
			differs = true
		}
	}
	if !differs {
		t.Fatal("changing the secret never changed the answer")
	}
}

func TestToday(t *testing.T) {
	code, body := get(t, testServer(), "/today")
	if code != 200 || body["puzzle_id"] != "2026-11-17" || body["max_guesses"] != float64(6) {
		t.Fatalf("got %d %v", code, body)
	}
	if _, ok := body["trace"]; !ok {
		t.Fatal("missing trace")
	}
}

func TestValidate(t *testing.T) {
	s := testServer()
	cases := map[string]bool{"crane": true, "zebus": true, "CRANE": true, "qqqqq": false, "": false}
	for word, want := range cases {
		_, body := get(t, s, "/validate?word="+word)
		if body["valid"] != want {
			t.Errorf("validate(%q) = %v, want %v", word, body["valid"], want)
		}
	}
}

func TestAnswerRejectsBadAndFutureIDs(t *testing.T) {
	s := testServer()
	cases := map[string]int{
		"2026-11-17": 200,
		"2026-11-18": 200, // one day of slack for clock skew
		"2026-11-19": 403,
		"2026-13-40": 400,
		"tomorrow":   400,
	}
	for id, want := range cases {
		if code, body := get(t, s, "/answer?puzzle_id="+id); code != want {
			t.Errorf("answer(%q) = %d %v, want %d", id, code, body, want)
		}
	}
}
