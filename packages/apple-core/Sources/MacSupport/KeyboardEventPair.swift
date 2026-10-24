/// Emits a keyboard down/up pair only after both events are created and configured.
public enum KeyboardEventPair {
    @discardableResult
    public static func emit<Event>(
        create: (Bool) -> Event?,
        configure: (Event, Bool) -> Void,
        post: (Event) -> Void
    ) -> Bool {
        guard let down = create(true), let up = create(false) else { return false }
        configure(down, true)
        configure(up, false)
        post(down)
        post(up)
        return true
    }
}
