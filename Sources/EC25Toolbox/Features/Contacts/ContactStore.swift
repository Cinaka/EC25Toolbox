import AppKit
import Contacts
import Foundation

/// Main-actor observable façade over the system Contacts database: tracks
/// authorization, keeps a snapshot for name/number matching, and refreshes
/// when the user edits contacts elsewhere.
@MainActor
final class ContactStore: ObservableObject {
    @Published private(set) var authorization: ContactsAuthorizationState = .notDetermined
    @Published private(set) var contacts: [ContactRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private let service: any ContactsProviding
    /// Only touched in `init` (main actor) and read in `deinit`; the
    /// `nonisolated(unsafe)` lets the nonisolated deinit remove the observer.
    nonisolated(unsafe) private var changeObserver: NSObjectProtocol?
    /// One snapshot refresh at a time; later requests coalesce into a trailing
    /// reload instead of piling up concurrent fetches.
    private var reloadPending = false
    /// Kept so an explicit request can wait out an in-flight status poll
    /// before prompting, keeping the two writes to `authorization` ordered.
    /// Readable so tests can await the initial refresh.
    private(set) var statusRefreshTask: Task<Void, Never>?

    init(service: any ContactsProviding = ContactsService()) {
        self.service = service
        changeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStoreChange()
            }
        }
        refreshAuthorizationStatus()
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    /// Re-reads the authorization state without prompting, loading the
    /// snapshot when access was already granted from a previous session.
    func refreshAuthorizationStatus() {
        statusRefreshTask = Task { [weak self] in
            guard let self else { return }
            let state = ContactsAuthorizationState(await self.service.authorizationStatus())
            self.authorization = state
            if state.allowsReading, self.contacts.isEmpty {
                await self.reload()
            }
        }
    }

    /// Runs the system permission prompt when undetermined, then loads the
    /// snapshot on success.
    func requestAccessIfNeeded() async {
        await statusRefreshTask?.value
        var state = ContactsAuthorizationState(await service.authorizationStatus())
        if state == .notDetermined {
            do {
                state = try await service.requestAccess() ? .authorized : .denied
            } catch {
                lastError = error.localizedDescription
                state = ContactsAuthorizationState(await service.authorizationStatus())
            }
        }
        authorization = state
        if state.allowsReading {
            await reload()
        } else {
            contacts = []
        }
    }

    /// Replaces the snapshot from the backing service. `CNContactStoreDidChange`
    /// arrives as a single notice per external edit session, so a coalesced
    /// refetch is the refresh strategy — anchor-based incremental history is
    /// not worth its state management for a menu-bar tool.
    func reload() async {
        guard authorization.allowsReading else {
            contacts = []
            return
        }
        guard !isRefreshing else {
            reloadPending = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            contacts = try await service.fetchContacts()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        if reloadPending {
            reloadPending = false
            await reload()
        }
    }

    private func handleStoreChange() {
        guard authorization.allowsReading else { return }
        Task { await reload() }
    }

    // MARK: - Lookups

    /// Contact matching a phone number, or nil when none matches. Powers both
    /// name and avatar resolution for calls and history rows.
    func contact(forNumber number: String) -> ContactRecord? {
        guard !PhoneNumberMatcher.digits(number).isEmpty else { return nil }
        return contacts.first { contact in
            contact.phoneNumbers.contains { PhoneNumberMatcher.matches($0.value, number) }
        }
    }

    /// Display name for a phone number, or nil when no contact matches.
    func displayName(forNumber number: String) -> String? {
        contact(forNumber: number)?.displayName
    }

    /// Contacts filtered by a free-form name or number query; an empty query
    /// returns the full snapshot.
    func search(_ query: String) -> [ContactRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return contacts }
        return contacts.filter { $0.matches(query: trimmed) }
    }
}

/// Opens the Contacts pane of System Settings when the user previously denied
/// access; only `.denied` can be fixed there (`.restricted` is managed by MDM
/// or Screen Time).
enum ContactsSettingsOpener {
    private static let privacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
    )!

    static func openPrivacyPane() {
        NSWorkspace.shared.open(privacyURL)
    }
}
