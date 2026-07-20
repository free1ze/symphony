defmodule SymphonyElixir.AgentRunnerThreadResumeTest do
  use SymphonyElixir.TestSupport

  test "reuses the saved thread on redispatch and starts fresh after routing labels change" do
    test_root = temp_root("reuse")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      install_fake_codex(codex_binary, :resume_ok)
      configure_runner(workspace_root, codex_binary, trace_file)

      issue = issue(["backend", "task:code"])
      state_fetcher = done_state_fetcher(issue)

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert :ok = AgentRunner.run(%{issue | state: "Rework"}, nil, issue_state_fetcher: state_fetcher)

      changed_route_issue = %{issue | labels: ["backend", "task:planning"]}

      assert :ok =
               AgentRunner.run(changed_route_issue, nil, issue_state_fetcher: done_state_fetcher(changed_route_issue))

      methods = traced_methods(trace_file)
      assert Enum.count(methods, &(&1 == "thread/start")) == 2
      assert Enum.count(methods, &(&1 == "thread/resume")) == 1
      assert Enum.count(methods, &(&1 == "turn/start")) == 3
    after
      System.delete_env("SYMP_TEST_CODEX_THREAD_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "falls back to a new thread when the saved thread cannot be resumed" do
    test_root = temp_root("fallback")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      install_fake_codex(codex_binary, :resume_fails)
      configure_runner(workspace_root, codex_binary, trace_file)

      issue = issue(["task:code"])
      state_fetcher = done_state_fetcher(issue)

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      methods = traced_methods(trace_file)
      assert Enum.count(methods, &(&1 == "thread/start")) == 2
      assert Enum.count(methods, &(&1 == "thread/resume")) == 1
      assert Enum.count(methods, &(&1 == "turn/start")) == 2

      state_path = Path.join([workspace_root, issue.identifier, ".symphony", "thread.json"])
      assert Jason.decode!(File.read!(state_path))["threadId"] == "thread-fresh"
    after
      System.delete_env("SYMP_TEST_CODEX_THREAD_TRACE")
      File.rm_rf(test_root)
    end
  end

  defp temp_root(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-agent-thread-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp configure_runner(workspace_root, codex_binary, trace_file) do
    System.put_env("SYMP_TEST_CODEX_THREAD_TRACE", trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )
  end

  defp install_fake_codex(path, resume_behavior) do
    resume_response =
      case resume_behavior do
        :resume_ok ->
          ~s(printf '%s\\n' '{"id":4,"result":{"thread":{"id":"thread-fresh"}}}')

        :resume_fails ->
          ~s(printf '%s\\n' '{"id":4,"error":{"code":-32001,"message":"thread not found"}}')
      end

    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/bin/sh
    trace_file="${SYMP_TEST_CODEX_THREAD_TRACE:-/tmp/codex-thread.trace}"
    printf '%s\n' 'RUN' >> "$trace_file"
    while IFS= read -r line; do
      printf 'JSON:%s\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-fresh"}}}'
          ;;
        *'"method":"thread/resume"'*)
          #{resume_response}
          ;;
        *'"method":"turn/start"'*)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-next"}}}'
          printf '%s\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp issue(labels) do
    %Issue{
      id: "issue-thread-redispatch",
      identifier: "MT-REDISPATCH",
      title: "Continue the same task",
      description: "Resume when the routing context is unchanged",
      state: "In Progress",
      labels: labels
    }
  end

  defp done_state_fetcher(issue) do
    fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
  end

  defp traced_methods(trace_file) do
    trace_file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "JSON:"))
    |> Enum.map(&String.trim_leading(&1, "JSON:"))
    |> Enum.map(&Jason.decode!/1)
    |> Enum.map(& &1["method"])
    |> Enum.reject(&is_nil/1)
  end
end
