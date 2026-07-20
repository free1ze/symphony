defmodule SymphonyElixir.Codex.ThreadStateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ThreadState

  test "persists a reusable thread in Git metadata without dirtying the workspace" do
    {workspace, issue} = git_workspace_and_issue()

    assert :ok = ThreadState.persist(workspace, issue, "thread-123")
    assert {:resume, "thread-123"} = ThreadState.resume_candidate(workspace, issue)

    assert {:resume, "thread-123"} =
             ThreadState.resume_candidate(workspace, %{
               issue
               | state: "Rework",
                 updated_at: DateTime.utc_now(),
                 labels: ["TASK:CODE", " backend "]
             })

    {status, 0} = System.cmd("git", ["-C", workspace, "status", "--porcelain"])
    assert status == ""
  end

  test "starts a new thread when routing labels change" do
    {workspace, issue} = git_workspace_and_issue()

    assert :ok = ThreadState.persist(workspace, issue, "thread-123")

    assert {:start, :routing_labels_changed} =
             ThreadState.resume_candidate(workspace, %{issue | labels: ["task:planning"]})
  end

  test "starts a new thread when saved state is malformed" do
    {workspace, issue} = git_workspace_and_issue()
    state_path = git_state_path(workspace)

    File.write!(state_path, "not-json")

    assert {:start, {:invalid_state_json, %Jason.DecodeError{}}} =
             ThreadState.resume_candidate(workspace, issue)
  end

  test "persists and validates thread state on the selected remote worker" do
    {workspace, issue} = git_workspace_and_issue()
    fake_bin = Path.join(Path.dirname(workspace), "bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    previous_path = System.get_env("PATH")

    File.mkdir_p!(fake_bin)

    File.write!(fake_ssh, """
    #!/bin/sh
    shift 2
    eval "$1"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    on_exit(fn -> restore_env("PATH", previous_path) end)

    assert :ok = ThreadState.persist(workspace, issue, "thread-remote", "worker-a")
    assert {:resume, "thread-remote"} = ThreadState.resume_candidate(workspace, issue, "worker-a")

    assert {:start, :worker_host_changed} =
             ThreadState.resume_candidate(workspace, issue, "worker-b")
  end

  defp git_workspace_and_issue do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-thread-state-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "MT-THREAD")
    File.mkdir_p!(workspace)
    System.cmd("git", ["-C", workspace, "init", "-b", "main"])

    on_exit(fn -> File.rm_rf(test_root) end)

    issue = %Issue{
      id: "issue-thread-state",
      identifier: "MT-THREAD",
      title: "Resume this issue",
      state: "In Progress",
      labels: ["backend", "task:code"]
    }

    {workspace, issue}
  end

  defp git_state_path(workspace) do
    {path, 0} =
      System.cmd("git", ["-C", workspace, "rev-parse", "--git-path", "symphony-thread.json"])

    Path.expand(String.trim(path), workspace)
  end
end
