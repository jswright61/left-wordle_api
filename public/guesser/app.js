const elements = {
  starterSection: document.querySelector("#starter-section"),
  starterChoices: document.querySelector("#starter-choices"),
  starterForm: document.querySelector("#custom-starter-form"),
  starterInput: document.querySelector("#custom-starter"),
  starterError: document.querySelector("#starter-error"),
  gameSection: document.querySelector("#game-section"),
  resetButton: document.querySelector("#reset-button"),
  resultReset: document.querySelector("#result-reset"),
  attemptLabel: document.querySelector("#attempt-label"),
  currentGuess: document.querySelector("#current-guess"),
  remainingCount: document.querySelector("#remaining-count"),
  possibilitiesBlock: document.querySelector("#possibilities-block"),
  possibilitiesList: document.querySelector("#possibilities-list"),
  evalError: document.querySelector("#eval-error"),
  guessSection: document.querySelector("#guess-section"),
  guessChoices: document.querySelector("#guess-choices"),
  highlightUnused: document.querySelector("#highlight-unused"),
  guessForm: document.querySelector("#custom-guess-form"),
  guessInput: document.querySelector("#custom-guess"),
  guessError: document.querySelector("#guess-error"),
  confirmation: document.querySelector("#guess-confirmation"),
  confirmationWord: document.querySelector("#confirmation-word"),
  confirmGuess: document.querySelector("#confirm-guess"),
  cancelGuess: document.querySelector("#cancel-guess"),
  resultPanel: document.querySelector("#result-panel"),
  resultLabel: document.querySelector("#result-label"),
  resultTitle: document.querySelector("#result-title"),
  resultDetail: document.querySelector("#result-detail"),
  playWordleLink: document.querySelector("#play-wordle-link"),
  historyList: document.querySelector("#history-list")
};

let state = null;
let pendingGuess = null;
let unusedHighlightActive = false;

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || "The request could not be completed");
  return body;
}

function normalizedWord(value) {
  return value.trim().toUpperCase();
}

function groupLabel(group) {
  return {
    unused: "Unused answer",
    orig_answers: "Previous answer",
    legal_words: "Legal word"
  }[group] || group;
}

function choiceCard(choice, index, type) {
  const weighted = choice.weighted_entropy === undefined
    ? ""
    : `<span>${choice.weighted_entropy.toFixed(2)} weighted</span>`;
  const badge = choice.group
    ? `<span class="group-badge group-${choice.group}">${groupLabel(choice.group)}</span>`
    : `<span class="group-badge ${choice.in_answer ? "" : "group-legal_words"}">${choice.in_answer ? "Answer" : "Legal"}</span>`;

  return `
    <button class="choice-card" type="button" data-choice-type="${type}" data-word="${choice.word}" data-unused-answer="${choice.unused_answer === true}">
      <span>
        <span class="choice-index">${index + 1}</span>
        <strong class="choice-word">${choice.word}</strong>
      </span>
      <span class="choice-meta">
        <span>${choice.entropy.toFixed(2)} entropy</span>
        ${weighted}
        ${badge}
      </span>
    </button>`;
}

async function loadStarterChoices() {
  try {
    const body = await api("api/starter-choices");
    elements.starterChoices.innerHTML = body.starter_choices
      .map((choice, index) => choiceCard(choice, index, "starter"))
      .join("");
  } catch (error) {
    elements.starterChoices.innerHTML = `<p class="error-message">${error.message}</p>`;
  }
}

async function startGame(starter) {
  elements.starterError.textContent = "";
  try {
    const body = await api("api/start", {
      method: "POST",
      body: JSON.stringify({ starter })
    });
    state = { ...body, history: [], suggestions: [], date: window.GAME_DATE || new Date().toISOString().slice(0, 10) };
    elements.starterSection.classList.add("hidden");
    elements.gameSection.classList.remove("hidden");
    elements.resetButton.classList.remove("hidden");
    elements.resultPanel.classList.add("hidden");
    renderTurn();
  } catch (error) {
    elements.starterError.textContent = error.message;
  }
}

function renderTurn() {
  elements.attemptLabel.textContent = `Attempt ${state.attempt} of 6`;
  elements.currentGuess.textContent = state.current_guess;
  elements.remainingCount.textContent = state.remaining_count;
  elements.evalError.textContent = "";
  elements.guessSection.classList.add("hidden");
  renderPossibilities(state.possibilities || [], state.unused_possibilities || []);
  renderHistory();
  evaluateCurrentGuess();
}

async function evaluateCurrentGuess() {
  try {
    const body = await api("api/evaluate", {
      method: "POST",
      body: JSON.stringify({ guess: state.current_guess, date: state.date })
    });
    await applyPattern(body.evaluation);
  } catch (error) {
    elements.evalError.textContent = error.message;
  }
}

function renderPossibilities(words, unusedWords) {
  const unusedAnswers = new Set(unusedWords);
  elements.possibilitiesBlock.classList.toggle("hidden", words.length === 0);
  elements.possibilitiesList.innerHTML = words
    .map((word) => `<span class="word-chip" data-unused-answer="${unusedAnswers.has(word)}">${word}</span>`)
    .join("");
}

function renderHistory() {
  if (state.history.length === 0) {
    elements.historyList.innerHTML = '<li class="empty-history">Patterns will appear here.</li>';
    return;
  }

  elements.historyList.innerHTML = state.history.map((item, index) => `
    <li class="history-item">
      <span>${index + 1}</span>
      <span>
        <span class="history-word">${item.guess}</span><br>
        <span class="history-pattern">${item.pattern}</span>
      </span>
      <span class="history-remaining">${item.remaining} left</span>
    </li>`).join("");
}

async function applyPattern(pattern) {
  const guess = state.current_guess;
  try {
    const body = await api("api/turn", {
      method: "POST",
      body: JSON.stringify({
        attempt: state.attempt,
        guess,
        pattern,
        remaining: state.remaining
      })
    });

    state.history.push({ guess, pattern, remaining: body.remaining_count });
    state.remaining = body.remaining || [];
    state.remaining_count = body.remaining_count;
    state.possibilities = body.possibilities || [];
    state.unused_possibilities = body.unused_possibilities || [];

    if (body.status === "continue") {
      state.attempt = body.attempt;
      state.suggestions = body.suggestions;
      showGuessChoices();
      return;
    }

    if (body.status === "solved") {
      finishGame("Solved", `${guess} solved in ${body.attempt} attempts.`, state.history.map((h) => h.guess));
    } else if (body.status === "answer") {
      finishGame("One answer remains", `The answer must be ${body.answer}.`, [...state.history.map((h) => h.guess), body.answer]);
    } else if (body.status === "no_answers") {
      finishGame("No answers remain", "Check the patterns entered for this game.");
    } else {
      finishGame("Six attempts used", `${body.remaining_count} possibilities still remain.`);
    }
  } catch (error) {
    elements.evalError.textContent = error.message;
  }
}

function showGuessChoices() {
  elements.attemptLabel.textContent = `Attempt ${state.attempt} of 6`;
  elements.currentGuess.textContent = "Choose a guess";
  elements.remainingCount.textContent = state.remaining_count;
  elements.guessSection.classList.remove("hidden");
  elements.guessChoices.innerHTML = state.suggestions
    .slice(0, 9)
    .map((choice, index) => choiceCard(choice, index, "guess"))
    .join("");
  unusedHighlightActive = false;
  elements.guessInput.value = "";
  elements.guessError.textContent = "";
  elements.confirmation.classList.add("hidden");
  renderPossibilities(state.possibilities || [], state.unused_possibilities || []);
  updateUnusedHighlight();
  renderHistory();
}

function updateUnusedHighlight() {
  const hasUnusedAnswers = elements.gameSection.querySelector('[data-unused-answer="true"]') !== null;
  if (!hasUnusedAnswers) unusedHighlightActive = false;
  elements.highlightUnused.disabled = !hasUnusedAnswers;
  elements.highlightUnused.setAttribute("aria-pressed", String(unusedHighlightActive));
  elements.highlightUnused.textContent = unusedHighlightActive
    ? "Hide unused highlights"
    : "Highlight unused answers";
  elements.gameSection.classList.toggle("show-unused-answers", unusedHighlightActive && hasUnusedAnswers);
}

function selectGuess(word) {
  state.current_guess = word;
  renderTurn();
}

async function validateCustomGuess(word) {
  elements.guessError.textContent = "";
  elements.confirmation.classList.add("hidden");
  try {
    const body = await api("api/validate-word", {
      method: "POST",
      body: JSON.stringify({ word, remaining: state.remaining })
    });
    if (!body.valid) {
      elements.guessError.textContent = `${body.word || word} is not in the legal words list.`;
    } else if (body.in_remaining) {
      selectGuess(body.word);
    } else {
      pendingGuess = body.word;
      elements.confirmationWord.textContent = body.word;
      elements.confirmation.classList.remove("hidden");
    }
  } catch (error) {
    elements.guessError.textContent = error.message;
  }
}

function finishGame(title, detail, playGuesses = null) {
  elements.remainingCount.textContent = state.remaining_count;
  elements.guessSection.classList.add("hidden");
  elements.resultTitle.textContent = title;
  elements.resultDetail.textContent = detail;
  elements.resultPanel.classList.remove("hidden");
  renderPossibilities(state.possibilities || [], state.unused_possibilities || []);
  renderHistory();

  if (playGuesses && playGuesses.length > 0 && window.WORDLE_BASE_URL) {
    const params = new URLSearchParams({gameDate: state.date});
    playGuesses.forEach((g, i) => params.set(`g${i + 1}`, g));
    elements.playWordleLink.href = `${window.WORDLE_BASE_URL}?${params}`;
    elements.playWordleLink.classList.remove("hidden");
  } else {
    elements.playWordleLink.classList.add("hidden");
  }
}

function resetGame() {
  state = null;
  pendingGuess = null;
  unusedHighlightActive = false;
  elements.gameSection.classList.remove("show-unused-answers");
  elements.gameSection.classList.add("hidden");
  elements.starterSection.classList.remove("hidden");
  elements.resetButton.classList.add("hidden");
  elements.starterInput.value = "";
  elements.starterError.textContent = "";
  window.scrollTo({ top: 0, behavior: "smooth" });
}

elements.starterChoices.addEventListener("click", (event) => {
  const button = event.target.closest("[data-choice-type='starter']");
  if (button) startGame(button.dataset.word);
});

elements.guessChoices.addEventListener("click", (event) => {
  const button = event.target.closest("[data-choice-type='guess']");
  if (button) selectGuess(button.dataset.word);
});

elements.starterForm.addEventListener("submit", (event) => {
  event.preventDefault();
  startGame(normalizedWord(elements.starterInput.value));
});

elements.guessForm.addEventListener("submit", (event) => {
  event.preventDefault();
  validateCustomGuess(normalizedWord(elements.guessInput.value));
});

elements.confirmGuess.addEventListener("click", () => {
  if (pendingGuess) selectGuess(pendingGuess);
  pendingGuess = null;
});

elements.cancelGuess.addEventListener("click", () => {
  pendingGuess = null;
  elements.confirmation.classList.add("hidden");
});

elements.highlightUnused.addEventListener("click", () => {
  if (elements.highlightUnused.disabled) return;
  unusedHighlightActive = !unusedHighlightActive;
  updateUnusedHighlight();
});

elements.resetButton.addEventListener("click", resetGame);
elements.resultReset.addEventListener("click", resetGame);

loadStarterChoices();
