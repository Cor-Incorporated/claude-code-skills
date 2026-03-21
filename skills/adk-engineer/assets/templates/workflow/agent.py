"""
Workflow Agent Template
Demonstrates Sequential, Parallel, and Loop workflow patterns.
"""

from adk.agents import LlmAgent, SequentialAgent, ParallelAgent, LoopAgent
from adk.tools import Tool


# ============================================================================
# Example 1: Sequential Pipeline
# ============================================================================

def extract_text(document: str) -> str:
    """Extract text from document."""
    # TODO: Implement extraction logic
    return f"Extracted text from {document}"


def validate_text(text: str) -> dict:
    """Validate extracted text."""
    # TODO: Implement validation logic
    return {"valid": True, "text": text}


extract_tool = Tool(name="extract_text", function=extract_text)
validate_tool = Tool(name="validate_text", function=validate_text)

extractor = LlmAgent(
    name="Extractor",
    instruction="Extract text from the input document.",
    tools=[extract_tool],
    output_key="extracted_text",
)

validator = LlmAgent(
    name="Validator",
    instruction="Validate the {extracted_text} for completeness.",
    tools=[validate_tool],
    output_key="validation_result",
)

processor = LlmAgent(
    name="Processor",
    instruction="Process the validated text from {validation_result}.",
    output_key="processed_result",
)

# Sequential pipeline: extractor → validator → processor
sequential_pipeline = SequentialAgent(
    name="SequentialPipeline",
    sub_agents=[extractor, validator, processor],
)


# ============================================================================
# Example 2: Parallel Execution
# ============================================================================

def check_security(code: str) -> dict:
    """Check code for security vulnerabilities."""
    # TODO: Implement security checks
    return {"vulnerabilities": [], "status": "safe"}


def check_style(code: str) -> dict:
    """Check code style compliance."""
    # TODO: Implement style checks
    return {"issues": [], "status": "compliant"}


def check_performance(code: str) -> dict:
    """Analyze code performance."""
    # TODO: Implement performance analysis
    return {"bottlenecks": [], "status": "optimized"}


security_tool = Tool(name="check_security", function=check_security)
style_tool = Tool(name="check_style", function=check_style)
performance_tool = Tool(name="check_performance", function=check_performance)

security_checker = LlmAgent(
    name="SecurityChecker",
    instruction="Check code for security vulnerabilities.",
    tools=[security_tool],
    output_key="security_report",
)

style_checker = LlmAgent(
    name="StyleChecker",
    instruction="Check code for style compliance.",
    tools=[style_tool],
    output_key="style_report",
)

performance_checker = LlmAgent(
    name="PerformanceChecker",
    instruction="Analyze code performance.",
    tools=[performance_tool],
    output_key="performance_report",
)

# Parallel execution: all checks run simultaneously
parallel_checks = ParallelAgent(
    name="ParallelChecks",
    sub_agents=[security_checker, style_checker, performance_checker],
)

# Aggregator to combine results
aggregator = LlmAgent(
    name="Aggregator",
    instruction="""
    Combine the results from:
    - {security_report}
    - {style_report}
    - {performance_report}

    Create a comprehensive code review summary.
    """,
    output_key="final_review",
)

# Complete workflow: parallel checks → aggregation
code_review_workflow = SequentialAgent(
    name="CodeReviewWorkflow",
    sub_agents=[parallel_checks, aggregator],
)


# ============================================================================
# Example 3: Validation Loop (Generator-Critic Pattern)
# ============================================================================

def execute_query(query: str) -> dict:
    """Execute SQL query and return results."""
    # TODO: Implement query execution
    return {"success": False, "error": "Syntax error"}


query_tool = Tool(name="execute_query", function=execute_query)

generator = LlmAgent(
    name="QueryGenerator",
    instruction="""
    Generate a SQL query based on the user's request.

    If you receive {feedback}, fix the query based on the feedback.
    """,
    output_key="generated_query",
)

critic = LlmAgent(
    name="QueryCritic",
    instruction="""
    Validate the {generated_query}.

    Use the execute_query tool to test it.

    If valid, output "PASS".
    If invalid, describe the specific errors that need to be fixed.
    """,
    tools=[query_tool],
    output_key="feedback",
)

# Loop until query passes validation
validation_loop = LoopAgent(
    name="ValidationLoop",
    sub_agents=[generator, critic],
    condition_key="feedback",
    exit_condition="PASS",
    max_iterations=5,  # Safety limit
)


# ============================================================================
# Root Agent: Choose Workflow Based on Task
# ============================================================================

root_agent = LlmAgent(
    name="WorkflowOrchestrator",
    model="gemini-2.0-flash",
    instruction="""
    You orchestrate different workflow patterns based on the task.

    Available workflows:
    1. SequentialPipeline - For step-by-step data processing
    2. CodeReviewWorkflow - For parallel code analysis
    3. ValidationLoop - For iterative query generation and validation

    Choose the appropriate workflow based on the user's request.
    """,
    sub_agents=[sequential_pipeline, code_review_workflow, validation_loop],
)


if __name__ == "__main__":
    # Test the workflow system locally
    from adk.runtime import run_cli

    print("Available workflows:")
    print("1. Sequential Pipeline - Process documents step by step")
    print("2. Code Review - Parallel analysis with aggregation")
    print("3. Query Generation - Validation loop with retries")
    print()

    run_cli(root_agent)
