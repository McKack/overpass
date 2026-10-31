// Closes an issue once its fix is out, as arctim-janitor, saying what the problem was. Run by
// .github/workflows/issue-update.yml; test with `node --test .github/scripts/`. Most reports come through the report
// relay, whose sender has no GitHub account, can't reply here and gets no notice of a comment, so nothing waits for an
// answer and the comment points back to OverPass.

const OUTCOMES = {
  verified: 'Fixed: the problem was reproduced, and the fix was tested against it.',
  untested: "This should work now, but the fix hasn't been tested against the problem itself, so it may need a try on your side.",
};
const AGAIN = 'Closing this. If it still happens, send a new report from OverPass.';

function comment({ problem, outcome, release }) {
  if (!Object.hasOwn(OUTCOMES, outcome)) throw new Error(`Unknown outcome: ${outcome}`);
  const text = (problem || '').trim();
  if (!text) throw new Error('The comment needs a description of the problem.');
  if (!release?.trim()) throw new Error('The comment needs the release with the fix.');
  return `${text}\n\n${OUTCOMES[outcome]} It's in OverPass ${release.trim()}. ${AGAIN}`;
}

/// The workflow's step: comments and closes the issue, or with no description only closes it.
async function run({ github, context, inputs }) {
  const target = { ...context.repo, issue_number: Number(inputs.issue) };
  if (inputs.problem?.trim()) await github.rest.issues.createComment({ ...target, body: comment(inputs) });
  await github.rest.issues.update({ ...target, state: 'closed', state_reason: 'completed' });
}

module.exports = { comment, run };
