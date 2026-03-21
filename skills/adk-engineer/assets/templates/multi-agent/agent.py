"""
Multi-Agent System Template
A coordinator agent with multiple specialist sub-agents.
"""

from adk.agents import LlmAgent
from adk.tools import Tool


# ============================================================================
# Specialist Agent 1: Data Specialist
# ============================================================================

def fetch_data(query: str) -> dict:
    """Fetch data from external source."""
    # TODO: Implement your data fetching logic
    return {"status": "success", "data": f"Data for: {query}"}


data_tool = Tool(
    name="fetch_data",
    description="Fetch data from the data source.",
    function=fetch_data,
)

data_specialist = LlmAgent(
    name="DataSpecialist",
    model="gemini-2.0-flash",
    description="Handles data fetching and retrieval tasks. Specializes in database queries and external API calls.",
    instruction="""
    You are a data specialist.

    Your responsibilities:
    - Fetch data from external sources using the fetch_data tool
    - Validate data format and completeness
    - Handle data retrieval errors gracefully

    Always ensure data quality before returning results.
    """,
    tools=[data_tool],
    output_key="data_result",
)


# ============================================================================
# Specialist Agent 2: Analysis Specialist
# ============================================================================

def analyze_data(data: dict) -> dict:
    """Analyze data and generate insights."""
    # TODO: Implement your analysis logic
    return {
        "insights": "Analysis complete",
        "summary": f"Analyzed {len(str(data))} bytes of data",
    }


analysis_tool = Tool(
    name="analyze_data",
    description="Perform analysis on provided data.",
    function=analyze_data,
)

analysis_specialist = LlmAgent(
    name="AnalysisSpecialist",
    model="gemini-2.0-flash",
    description="Handles data analysis and insight generation. Specializes in pattern recognition and trend analysis.",
    instruction="""
    You are an analysis specialist.

    Your responsibilities:
    - Analyze data from {data_result}
    - Identify patterns and trends
    - Generate actionable insights

    Provide clear, data-driven recommendations.
    """,
    tools=[analysis_tool],
    output_key="analysis_result",
)


# ============================================================================
# Specialist Agent 3: Report Specialist
# ============================================================================

def generate_report(data: dict, analysis: dict) -> str:
    """Generate formatted report."""
    # TODO: Implement your report generation logic
    return f"""
    # Report

    ## Data Summary
    {data.get('summary', 'No data available')}

    ## Analysis
    {analysis.get('insights', 'No insights available')}

    ## Recommendations
    - Review findings
    - Take action as needed
    """


report_tool = Tool(
    name="generate_report",
    description="Generate a formatted report from data and analysis.",
    function=generate_report,
)

report_specialist = LlmAgent(
    name="ReportSpecialist",
    model="gemini-2.0-flash",
    description="Handles report generation and documentation. Specializes in creating clear, actionable reports.",
    instruction="""
    You are a report specialist.

    Your responsibilities:
    - Create reports from {data_result} and {analysis_result}
    - Format information clearly
    - Include actionable recommendations

    Ensure reports are professional and easy to understand.
    """,
    tools=[report_tool],
    output_key="final_report",
)


# ============================================================================
# Coordinator Agent
# ============================================================================

root_agent = LlmAgent(
    name="CoordinatorAgent",
    model="gemini-2.0-flash",
    instruction="""
    You are a coordinator that manages specialist agents.

    When the user makes a request:
    1. Determine which specialist(s) are needed
    2. Delegate to appropriate specialist(s)
    3. Coordinate their work if multiple specialists are involved

    Available specialists:
    - DataSpecialist: For data fetching and retrieval
    - AnalysisSpecialist: For data analysis and insights
    - ReportSpecialist: For report generation

    Route requests intelligently based on the user's needs.
    """,
    sub_agents=[data_specialist, analysis_specialist, report_specialist],
)


if __name__ == "__main__":
    # Test the multi-agent system locally
    from adk.runtime import run_cli

    run_cli(root_agent)
