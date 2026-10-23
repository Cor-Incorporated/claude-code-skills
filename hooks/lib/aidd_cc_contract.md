## AIDD H17 report contract

H17 checks the final answer of every turn that used tools. End that answer with these lines, as its last lines:

- `Evidence: <command> | <line it printed, copied verbatim> | <UTC time, e.g. 2026-10-23T06:00:00Z>` for each result you report, one line per command. Cite only a command that you ran in this session after your last file change, and that exited 0.
- `Readback: <path> sha256=<64 hex digits>` when you say a file was saved, written or deployed. The path must be one you wrote in this session, hashed after the last write.
- `Status: complete`, `Status: partial` or `Status: unverified` as the very last line, with nothing else on it. `complete` needs the Evidence lines above. Use `partial` or `unverified` when something is not done or not checked.

Run each command you cite once, on its own: nothing joined to it with `;`, `&&`, `||`, `|` or `&`, and no `echo $?` or exit marker added. The gate reads the exit code the harness reports for that call, and a joined line reports one code for the whole line, so a command inside it counts as UNKNOWN. Do not cite a command that you ran only inside a longer line.
