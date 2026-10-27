// word-service owns the dictionary and the daily answer.
//
// It is the only service that knows DAILY_SECRET. The answer for a puzzle is
// HMAC-SHA256(secret, puzzle_id) mod len(answers), so every replica computes
// the same answer with no database and no shared state.
package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	_ "time/tzdata" // distroless has no zoneinfo; embed it so PUZZLE_TZ works
)

const (
	wordLength = 5
	maxGuesses = 6
)

var (
	wordRe     = regexp.MustCompile(`^[a-z]{5}$`)
	puzzleIDRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
)

type traceEntry struct {
	Service string `json:"service"`
	Pod     string `json:"pod"`
	Node    string `json:"node"`
}

type server struct {
	answers       []string
	allowed       map[string]struct{}
	secret        []byte
	loc           *time.Location
	maxFutureDays int
	self          traceEntry
	now           func() time.Time
}

func loadWords(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var words []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		w := strings.TrimSpace(strings.ToLower(sc.Text()))
		if wordRe.MatchString(w) {
			words = append(words, w)
		}
	}
	return words, sc.Err()
}

func newServer(answers, allowed []string, secret string, loc *time.Location, maxFutureDays int) *server {
	set := make(map[string]struct{}, len(allowed)+len(answers))
	for _, w := range allowed {
		set[w] = struct{}{}
	}
	for _, w := range answers {
		set[w] = struct{}{}
	}
	host, _ := os.Hostname()
	return &server{
		answers:       answers,
		allowed:       set,
		secret:        []byte(secret),
		loc:           loc,
		maxFutureDays: maxFutureDays,
		self: traceEntry{
			Service: "word-service",
			Pod:     envOr("POD_NAME", host),
			Node:    envOr("NODE_NAME", "local"),
		},
		now: time.Now,
	}
}

func (s *server) today() string {
	return s.now().In(s.loc).Format("2006-01-02")
}

func (s *server) answerFor(puzzleID string) string {
	mac := hmac.New(sha256.New, s.secret)
	mac.Write([]byte(puzzleID))
	sum := mac.Sum(nil)
	idx := binary.BigEndian.Uint64(sum[:8]) % uint64(len(s.answers))
	return s.answers[idx]
}

// checkPuzzleID rejects malformed ids and ids too far in the future, so a
// client cannot ask for tomorrow's answer ahead of time.
func (s *server) checkPuzzleID(id string) (int, string) {
	if !puzzleIDRe.MatchString(id) {
		return http.StatusBadRequest, "puzzle_id must be YYYY-MM-DD"
	}
	day, err := time.ParseInLocation("2006-01-02", id, s.loc)
	if err != nil {
		return http.StatusBadRequest, "puzzle_id is not a real date"
	}
	limit := s.now().In(s.loc).AddDate(0, 0, s.maxFutureDays)
	if day.After(limit) {
		return http.StatusForbidden, "puzzle_id is in the future"
	}
	return 0, ""
}

func (s *server) writeJSON(w http.ResponseWriter, status int, body map[string]any) {
	body["trace"] = []traceEntry{s.self}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(body)
}

func (s *server) handleToday(w http.ResponseWriter, r *http.Request) {
	s.writeJSON(w, http.StatusOK, map[string]any{
		"puzzle_id":   s.today(),
		"length":      wordLength,
		"max_guesses": maxGuesses,
	})
}

func (s *server) handleValidate(w http.ResponseWriter, r *http.Request) {
	word := strings.ToLower(r.URL.Query().Get("word"))
	_, ok := s.allowed[word]
	s.writeJSON(w, http.StatusOK, map[string]any{"word": word, "valid": ok})
}

func (s *server) handleAnswer(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("puzzle_id")
	if status, msg := s.checkPuzzleID(id); status != 0 {
		s.writeJSON(w, status, map[string]any{"error": msg})
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"puzzle_id": id, "answer": s.answerFor(id)})
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /today", s.handleToday)
	mux.HandleFunc("GET /validate", s.handleValidate)
	mux.HandleFunc("GET /answer", s.handleAnswer)
	ok := func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) }
	mux.HandleFunc("GET /healthz", ok)
	mux.HandleFunc("GET /readyz", ok)
	return logRequests(mux)
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
			next.ServeHTTP(w, r)
			return
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, rec.status, time.Since(start).Round(time.Microsecond))
	})
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	noop := flag.Bool("noop", false, "exit immediately (used by the image pre-pull DaemonSet)")
	flag.Parse()
	if *noop {
		return
	}

	secret := os.Getenv("DAILY_SECRET")
	if secret == "" {
		log.Fatal("DAILY_SECRET is not set")
	}
	dir := envOr("WORDS_DIR", "/app/words")
	answers, err := loadWords(filepath.Join(dir, "answers.txt"))
	if err != nil || len(answers) == 0 {
		log.Fatalf("loading answers: %v (got %d words)", err, len(answers))
	}
	allowed, err := loadWords(filepath.Join(dir, "allowed.txt"))
	if err != nil {
		log.Fatalf("loading allowed: %v", err)
	}
	loc, err := time.LoadLocation(envOr("PUZZLE_TZ", "Asia/Bangkok"))
	if err != nil {
		log.Fatalf("PUZZLE_TZ: %v", err)
	}
	var maxFuture int
	fmt.Sscanf(envOr("PUZZLE_MAX_FUTURE_DAYS", "1"), "%d", &maxFuture)

	s := newServer(answers, allowed, secret, loc, maxFuture)
	addr := ":" + envOr("PORT", "8080")
	log.Printf("word-service on %s: %d answers, %d allowed, tz=%s, pod=%s node=%s",
		addr, len(answers), len(s.allowed), loc, s.self.Pod, s.self.Node)
	log.Fatal(http.ListenAndServe(addr, s.routes()))
}
