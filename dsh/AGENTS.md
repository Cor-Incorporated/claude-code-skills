<!-- Deployed by claude-code-skills setup.sh from dsh/AGENTS.md (AIDD H17). setup.sh overwrites this file while this line is here; delete the line to keep your own edits. -->
# AIDD H17 evidence (dsh)

The H17 gate checks your final report against the tool calls it saw.

- After your last change, run the verification command once, on its own: nothing joined to it with `;`, `&&`, `||`, `|` or `&`, and no `echo $?` or exit marker added. The gate reads the exit code the harness reports for that call. A joined line reports one code for the whole line, so the command inside it counts as UNKNOWN.
- Cite exactly that command in the `Evidence:` line. Do not cite a command that you ran only inside a longer line.
