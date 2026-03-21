# Workflow Agent Template

Demonstrates three common ADK workflow patterns: Sequential, Parallel, and Loop.

## Workflows Included

### 1. Sequential Pipeline

**Use Case:** Step-by-step data processing

```
Extractor → Validator → Processor
```

**Example Query:** "Process document.pdf"

**Pattern:** Each agent depends on the previous one's output.

### 2. Parallel Code Review

**Use Case:** Independent tasks running concurrently

```
┌─ SecurityChecker ─┐
├─ StyleChecker    ─┤ → Aggregator → Final Review
└─ PerformanceCheck ┘
```

**Example Query:** "Review this code for quality"

**Pattern:** Parallel execution with result aggregation.

### 3. Validation Loop

**Use Case:** Iterative refinement until criteria met

```
Generator → Critic → [if not PASS, loop back]
```

**Example Query:** "Generate a SQL query to find top customers"

**Pattern:** Generator-Critic pattern with validation loop.

## Setup

1. Install dependencies:
```bash
pip install -r requirements.txt
```

2. Set environment variables:
```bash
export GOOGLE_AI_API_KEY=your_api_key_here
```

## Usage

### CLI Mode
```bash
python agent.py
```

### Web UI Mode
```bash
adk ui --agent-file agent.py
```

### Programmatic Usage
```python
from agent import sequential_pipeline, code_review_workflow, validation_loop

# Use sequential pipeline
result = sequential_pipeline.run("Process my document")

# Use parallel code review
result = code_review_workflow.run("Review this Python code")

# Use validation loop
result = validation_loop.run("Generate query for user data")
```

## Workflow Pattern Details

### Sequential Pattern

```python
sequential = SequentialAgent(
    sub_agents=[step1, step2, step3]
)
```

**Characteristics:**
- Linear execution order
- Each agent uses previous agent's output
- Deterministic and easy to debug

### Parallel Pattern

```python
parallel = ParallelAgent(
    sub_agents=[task1, task2, task3]
)
```

**Characteristics:**
- Concurrent execution
- Each agent writes to unique `output_key`
- Aggregation step combines results

### Loop Pattern

```python
loop = LoopAgent(
    sub_agents=[generator, critic],
    condition_key="feedback",
    exit_condition="PASS",
    max_iterations=5
)
```

**Characteristics:**
- Iterative execution until condition met
- Safety limit via `max_iterations`
- Useful for validation and refinement

## Customization

### Add Sequential Step

```python
new_step = LlmAgent(
    instruction="Process {previous_output}",
    output_key="new_output"
)

sequential = SequentialAgent(
    sub_agents=[step1, step2, new_step]  # Add to chain
)
```

### Add Parallel Task

```python
new_checker = LlmAgent(
    instruction="Perform new check",
    output_key="new_report"  # Must be unique!
)

parallel = ParallelAgent(
    sub_agents=[check1, check2, new_checker]
)
```

### Modify Loop Condition

```python
loop = LoopAgent(
    sub_agents=[generator, critic],
    condition_key="status",       # Check this state key
    exit_condition="APPROVED",    # Exit when this value
    max_iterations=10            # Safety limit
)
```

## Combining Patterns

Real-world systems often combine patterns:

```python
# Parallel analysis → Sequential processing → Validation loop
workflow = SequentialAgent(
    sub_agents=[
        ParallelAgent(sub_agents=[analyze1, analyze2]),
        process_step,
        LoopAgent(sub_agents=[generate, validate])
    ]
)
```

## Design Patterns

See [adk-patterns.md](../../../references/adk-patterns.md) for:
- When to use each pattern
- Detailed implementation examples
- Pattern selection guide

## Deployment

See [adk-deployment.md](../../../references/adk-deployment.md) for deployment options.
