def decompose(objective, completed_tasks, llm_config \\ %{})

      when is_binary(objective) and is_list(completed_tasks) do

    

    system_prompt = """

    You are the Master Planner (Generator node) in a dynamic, autonomous agent system.

    

    CORE PHILOSOPHY: LAZY HIERARCHICAL PLANNING

    Your goal is to break down tasks using "lazy evaluation." You do not need to plan every single atomic step of a complex goal from the beginning. Instead, you decompose the current objective into immediate, logical sub-tasks.

    

    You must classify every sub-task into one of two categories:

    

    1. HIGH-LEVEL "DELEGATE" NODES (Blocked / Unresolved)

       If a sub-task is abstract, complex, or requires discovering information before it can be executed (e.g., "Find the database credentials", "Figure out how to compile this project"), you must make it a "delegate" task. Do NOT guess the steps. A child agent will be spawned later to investigate and break this node down further.

       

    2. ACTIONABLE "TOOL" NODES (Unblocked / Ready)

       If a sub-task is fully understood and you know the exact, concrete inputs required, make it a "tool" task. These nodes will be executed immediately. They must be perfectly actionable.

       

    STRICT RULES FOR ACTIONABLE NODES:

    - Never emit placeholders, TODO text, or comment-only shell commands.

    - If details are missing (e.g., you don't know the exact filename or flag), DO NOT use a tool node. Emit a "delegate" node to figure it out instead.

    - For shell tasks, "args.command" must be a concrete, runnable command.

    - BAD shell command examples (NEVER output these):

      * "# Placeholder: run translator"

      * "TODO: figure out script"

      * "insert_command_here"

    - GOOD alternative when unknown:

      * {"type": "delegate", "objective": "Determine exact translator invocation and run it"}

      

    OUTPUT FORMAT:

    You must return ONLY a valid JSON array of task objects. Do not include markdown formatting like ```json unless explicitly requested by the parser, just return the raw array.

    """



    user_prompt = """

    CURRENT OBJECTIVE:

    #{objective}



    COMPLETED HISTORY:

    #{inspect(completed_tasks)}



    INSTRUCTIONS:

    Analyze the current objective and the completed history. Determine the immediate next steps required.

    

    Decompose the remaining work into an array of JSON objects.

    Each task object MUST include:

    - "id": A stable, short, unique identifier string (e.g., "setup_db", "read_readme").

    - "type": Strictly either "delegate" or "tool".

    - "objective": A clear, one-sentence description of what this sub-task achieves.

    

    If "type" is "tool", you MUST also include:

    - "tool": The exact Orchid tool name to use.

    - "args": A JSON object containing the exact arguments for the tool.

    

    Generate the JSON array now:

    """



    # Example of how you might pass this to your LLM module

    # Orchid.LLM.call(system_prompt: system_prompt, user_prompt: user_prompt, ...)

  end
