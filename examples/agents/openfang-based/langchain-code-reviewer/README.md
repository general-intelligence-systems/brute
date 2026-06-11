# langchain-code-reviewer

A bilingual (中文 output) principal-level code review agent.

Ported from **[RightNow-AI/openfang](https://github.com/RightNow-AI/openfang)** —
source: [`agents/langchain-code-reviewer/agent.py`](https://github.com/RightNow-AI/openfang/blob/main/agents/langchain-code-reviewer/agent.py).

Upstream is a Python LangChain chain (prompt | llm | parser); this port keeps
the system prompt verbatim and runs the chain through brute's
`Completion::LangChain` middleware (langchainrb), so install the optional
completions group first:

```sh
bundle config set --local with completions && bundle install
```

## Usage

```sh
export OPENAI_API_KEY=...
bundle exec ruby examples/agents/openfang-based/langchain-code-reviewer/agent.rb path/to/file.rb
git diff | bundle exec ruby examples/agents/openfang-based/langchain-code-reviewer/agent.rb
```
