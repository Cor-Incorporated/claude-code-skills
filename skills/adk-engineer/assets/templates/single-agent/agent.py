"""
Single Agent Template
A simple LLM agent with custom tools.
"""

from adk.agents import LlmAgent
from adk.tools import Tool


# Define custom tools
def search_database(query: str) -> str:
    """
    Search the database for information.

    Args:
        query: The search query

    Returns:
        Search results as a string
    """
    # TODO: Implement your database search logic
    return f"Results for: {query}"


def process_data(data: dict) -> dict:
    """
    Process data according to business logic.

    Args:
        data: Input data dictionary

    Returns:
        Processed data
    """
    # TODO: Implement your data processing logic
    return {"processed": True, "data": data}


# Create tool wrappers
search_tool = Tool(
    name="search_database",
    description="Search the database for relevant information.",
    function=search_database,
)

process_tool = Tool(
    name="process_data",
    description="Process data according to business rules.",
    function=process_data,
)


# Define the agent
root_agent = LlmAgent(
    name="MyAgent",
    model="gemini-2.0-flash",
    instruction="""
    You are a helpful assistant that can search a database and process data.

    When the user asks for information:
    1. Use the search_database tool to find relevant data
    2. If needed, use process_data to transform the results
    3. Provide a clear, concise response

    Always be professional and accurate.
    """,
    tools=[search_tool, process_tool],
)


if __name__ == "__main__":
    # Test the agent locally
    from adk.runtime import run_cli

    run_cli(root_agent)
