/* Minos playground editor logic */

const EXAMPLES = {
  basics: `-- Identity and higher-order functions
let id = fun x -> x

let const = fun x -> fun y -> x

let compose = fun f -> fun g -> fun x -> f (g x)

let apply = fun f -> fun x -> f x

-- Arithmetic and comparisons (built-in operators)
let double = fun n -> n + n

let positive = fun n -> n > 0
`,
  recursion: `-- Recursive functions
let rec fact = fun n ->
  if n == 0 then 1 else n * (fact (n - 1))

let rec fib = fun n ->
  if n < 2 then n else (fib (n - 1)) + (fib (n - 2))

-- Mutual recursion via let rec
let rec even = fun n ->
  if n == 0 then true else odd (n - 1)

let rec odd = fun n ->
  if n == 0 then false else even (n - 1)
`,
  records: `-- Row polymorphism: open records
let get_x = fun r -> r.x

let get_y = fun r -> r.y

-- Works on any record with field x
let incr_x = fun r -> r.x + 1

-- Record literals
let point = { x = 3, y = 4 }

-- Nested field access
let get_val = fun r -> r.inner

-- Type annotation
let annotated = (fun x -> x) : (a -> a)
`,
};

const DEFAULT_EXAMPLE = 'basics';

// ── CodeMirror setup ──────────────────────────────────────────────────────────

const editor = CodeMirror(document.getElementById('editor'), {
  value: EXAMPLES[DEFAULT_EXAMPLE],
  mode: 'mllike',
  lineNumbers: true,
  lineWrapping: false,
  indentUnit: 2,
  tabSize: 2,
  extraKeys: { Tab: cm => cm.execCommand('insertSoftTab') },
  theme: 'minos',
});

// ── Inference engine ──────────────────────────────────────────────────────────

function inferLine(line) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('--')) return null;
  try {
    return JSON.parse(Minos.infer(trimmed));
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

// ── Rendering ─────────────────────────────────────────────────────────────────

const output = document.getElementById('output');
const statusEl = document.getElementById('status');

function pad(s, n) {
  return s.length >= n ? s : s + ' '.repeat(n - s.length);
}

function escapeHtml(s) {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function render() {
  const lines = editor.getValue().split('\n');
  let ok = 0, fail = 0;
  const parts = lines.map(line => {
    const trimmed = line.trim();
    if (!trimmed) {
      return '<span class="line-empty"> </span>';
    }
    if (trimmed.startsWith('--')) {
      return '<span class="line-comment">' + escapeHtml(line) + '</span>';
    }
    const result = inferLine(line);
    if (!result) return '<span class="line-empty"> </span>';
    if (result.ok) {
      ok++;
      const padded = pad(escapeHtml(line), 36);
      return '<span class="line-ok">' + padded + '  : ' + escapeHtml(result.type) + '</span>';
    } else {
      fail++;
      const padded = pad(escapeHtml(line), 36);
      return '<span class="line-err">' + padded + '  -- ' + escapeHtml(result.error) + '</span>';
    }
  });

  output.innerHTML = parts.join('\n');

  const total = ok + fail;
  statusEl.innerHTML =
    '<span>' + total + ' expression' + (total === 1 ? '' : 's') + '</span>' +
    (ok   ? '<span class="ok">' + ok   + ' typed</span>' : '') +
    (fail ? '<span class="fail">' + fail + ' error' + (fail === 1 ? '' : 's') + '</span>' : '');
}

// ── Debounced update ──────────────────────────────────────────────────────────

let timer;
editor.on('change', () => {
  clearTimeout(timer);
  timer = setTimeout(render, 120);
});

// ── Example selector ──────────────────────────────────────────────────────────

const sel = document.getElementById('examples-select');
sel.addEventListener('change', () => {
  const key = sel.value;
  if (EXAMPLES[key]) {
    editor.setValue(EXAMPLES[key]);
    editor.clearHistory();
    sel.value = '';
  }
});

// ── Initial render ────────────────────────────────────────────────────────────

render();
