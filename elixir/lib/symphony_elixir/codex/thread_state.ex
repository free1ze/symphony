defmodule SymphonyElixir.Codex.ThreadState do
  @moduledoc """
  Persists the Codex thread associated with an issue workspace.

  The state lives in Git metadata when the workspace is a repository, keeping it
  out of the worktree. Non-Git workspaces fall back to `.symphony/thread.json`.
  """

  alias SymphonyElixir.{Config, SSH}
  alias SymphonyElixir.Tracker.Issue

  @version 1
  @git_state_name "symphony-thread.json"
  @fallback_state_path Path.join(".symphony", "thread.json")
  @max_state_bytes 64_000

  @type worker_host :: String.t() | nil
  @type resume_result :: {:resume, String.t()} | {:start, term()}

  @spec resume_candidate(Path.t(), Issue.t(), worker_host()) :: resume_result()
  def resume_candidate(workspace, %Issue{} = issue, worker_host \\ nil)
      when is_binary(workspace) do
    with :ok <- validate_issue_identity(issue),
         {:ok, payload} <- read_state(workspace, worker_host),
         :ok <- validate_payload(payload, workspace, issue, worker_host) do
      {:resume, payload["threadId"]}
    else
      {:error, reason} -> {:start, reason}
    end
  end

  @spec persist(Path.t(), Issue.t(), String.t(), worker_host()) :: :ok | {:error, term()}
  def persist(workspace, %Issue{} = issue, thread_id, worker_host \\ nil)
      when is_binary(workspace) and is_binary(thread_id) do
    with :ok <- validate_issue_identity(issue),
         :ok <- validate_thread_id(thread_id),
         {:ok, encoded} <- Jason.encode(state_payload(workspace, issue, thread_id, worker_host)) do
      write_state(workspace, encoded <> "\n", worker_host)
    end
  end

  defp validate_issue_identity(%Issue{id: issue_id, identifier: identifier}) do
    cond do
      not non_empty_string?(issue_id) -> {:error, :missing_issue_id}
      not non_empty_string?(identifier) -> {:error, :missing_issue_identifier}
      true -> :ok
    end
  end

  defp validate_thread_id(thread_id) do
    if non_empty_string?(thread_id), do: :ok, else: {:error, :invalid_thread_id}
  end

  defp state_payload(workspace, issue, thread_id, worker_host) do
    %{
      "version" => @version,
      "issueId" => issue.id,
      "issueIdentifier" => issue.identifier,
      "labels" => normalized_labels(issue.labels),
      "workspace" => workspace,
      "workerHost" => worker_host,
      "threadId" => thread_id
    }
  end

  defp validate_payload(payload, workspace, issue, worker_host) when is_map(payload) do
    expected = state_payload(workspace, issue, payload["threadId"], worker_host)

    cond do
      payload["version"] != @version -> {:error, :version_mismatch}
      not non_empty_string?(payload["threadId"]) -> {:error, :invalid_thread_id}
      payload["issueId"] != expected["issueId"] -> {:error, :issue_mismatch}
      payload["issueIdentifier"] != expected["issueIdentifier"] -> {:error, :identifier_mismatch}
      payload["labels"] != expected["labels"] -> {:error, :routing_labels_changed}
      payload["workspace"] != expected["workspace"] -> {:error, :workspace_changed}
      payload["workerHost"] != expected["workerHost"] -> {:error, :worker_host_changed}
      true -> :ok
    end
  end

  defp validate_payload(_payload, _workspace, _issue, _worker_host),
    do: {:error, :invalid_payload}

  defp normalized_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(fn label -> label |> String.trim() |> String.downcase() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalized_labels(_labels), do: []

  defp read_state(workspace, nil) do
    path = local_state_path(workspace)

    case File.read(path) do
      {:ok, encoded} when byte_size(encoded) <= @max_state_bytes -> decode_state(encoded)
      {:ok, _encoded} -> {:error, :state_too_large}
      {:error, :enoent} -> {:error, :state_missing}
      {:error, reason} -> {:error, {:state_read_failed, reason}}
    end
  end

  defp read_state(workspace, worker_host) when is_binary(worker_host) do
    script =
      remote_state_prelude(workspace) <>
        "\nif [ ! -f \"$state_path\" ]; then exit 44; fi\n" <>
        "size=$(wc -c < \"$state_path\")\n" <>
        "if [ \"$size\" -gt #{@max_state_bytes} ]; then exit 45; fi\n" <>
        "cat \"$state_path\""

    case run_remote(worker_host, script) do
      {:ok, {encoded, 0}} -> decode_state(encoded)
      {:ok, {_output, 44}} -> {:error, :state_missing}
      {:ok, {_output, 45}} -> {:error, :state_too_large}
      {:ok, {output, status}} -> {:error, {:state_read_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_state(encoded) do
    case Jason.decode(encoded) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, {:invalid_state_json, reason}}
    end
  end

  defp write_state(workspace, encoded, nil) do
    path = local_state_path(workspace)
    tmp_path = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp_path, encoded),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, {:state_write_failed, reason}}
    end
  end

  defp write_state(workspace, encoded, worker_host) when is_binary(worker_host) do
    script = """
    #{remote_state_prelude(workspace)}
    state_dir=$(dirname "$state_path")
    mkdir -p "$state_dir"
    tmp_path="$state_path.tmp.$$"
    trap 'rm -f "$tmp_path"' EXIT HUP INT TERM
    printf '%s' #{shell_escape(encoded)} > "$tmp_path"
    mv "$tmp_path" "$state_path"
    trap - EXIT HUP INT TERM
    """

    case run_remote(worker_host, script) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:state_write_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_state_path(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--git-path", @git_state_name], stderr_to_stdout: true) do
      {path, 0} -> Path.expand(String.trim(path), workspace)
      _ -> Path.join(workspace, @fallback_state_path)
    end
  end

  defp remote_state_prelude(workspace) do
    """
    set -eu
    workspace=#{shell_escape(workspace)}
    cd "$workspace"
    if git_path=$(git rev-parse --git-path #{@git_state_name} 2>/dev/null); then
      case "$git_path" in
        /*) state_path="$git_path" ;;
        *) state_path="$workspace/$git_path" ;;
      esac
    else
      state_path="$workspace/#{@fallback_state_path}"
    fi
    """
    |> String.trim()
  end

  defp run_remote(worker_host, script) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:thread_state_remote_failed, worker_host, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:thread_state_remote_timeout, worker_host, timeout_ms}}
    end
  end

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
