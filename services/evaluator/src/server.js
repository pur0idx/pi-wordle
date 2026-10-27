const express = require('express');
const os = require('os');
const { evaluate, RuleError } = require('./rules');

const self = {
  service: 'evaluator',
  pod: process.env.POD_NAME || os.hostname(),
  node: process.env.NODE_NAME || 'local',
};

const app = express();
app.use(express.json({ limit: '16kb' }));

app.use((req, res, next) => {
  if (req.path === '/healthz' || req.path === '/readyz') return next();
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - start) / 1e6;
    console.log(`${req.method} ${req.path} ${res.statusCode} ${ms.toFixed(2)}ms`);
  });
  next();
});

app.post('/evaluate', (req, res) => {
  const b = req.body || {};
  try {
    const result = evaluate({
      guess: b.guess,
      answer: b.answer,
      history: b.history,
      maxGuesses: b.max_guesses ?? 6,
      hardMode: Boolean(b.hard_mode),
    });
    res.json({ ...result, trace: [self] });
  } catch (err) {
    if (err instanceof RuleError) {
      return res.status(err.status).json({ error: err.message, trace: [self] });
    }
    throw err;
  }
});

app.get('/healthz', (req, res) => res.send('ok'));
app.get('/readyz', (req, res) => res.send('ok'));

const port = Number(process.env.PORT || 8080);
const server = app.listen(port, () => {
  console.log(`evaluator on :${port} pod=${self.pod} node=${self.node}`);
});

// Kubernetes sends SIGTERM on rollout/eviction; finish in-flight requests.
process.on('SIGTERM', () => server.close(() => process.exit(0)));
