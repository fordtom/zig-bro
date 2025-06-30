# zig-bro

A command-line wrapper that provides AI analysis. Use bro to get a summary of what happened when reading the trace yourself doesn't sound too appealing.

you will need an 'ANTHROPIC_API_KEY' environment variable set. If you require more brain power you can modify the API payload in llm.zig to enable thinking/use opus.

## Usage
Prefix any command with `bro` to get A summary instead of raw output:

```bash
bro cargo build
bro make test
bro cat error.log
```

Bro executes your command, captures stdout/stderr, and sends it to Claude for analysis.

## Current Limitations
- no interactive support - anything requiring input during the command won't work.
- not real-time - no printout of the existing stdout/stderr; all you get is the LLM output at the end.

Both of these I will eventually try to resolve. This is a 'learning Zig' project for me.

Inspired by [wut_rust](https://github.com/surajssc1232/wut_rust).