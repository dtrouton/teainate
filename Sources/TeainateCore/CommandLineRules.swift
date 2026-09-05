import Foundation

/// nil when an `off` invocation names a sensible selection; otherwise the message to
/// refuse it with. `--id` with `--all` is refused rather than letting `--all` win
/// silently: the caller named one hold and would get every hold released.
public func offSelectionProblem(id: String?, all: Bool, untracked: Bool) -> String? {
    if id != nil && all { return "Choose --id or --all, not both." }
    if id == nil && !all && !untracked { return "Specify --id <id>, --all, or --untracked." }
    return nil
}
