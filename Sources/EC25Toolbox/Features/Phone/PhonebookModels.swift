import Foundation

/// Read-only snapshot of the card/module phonebook capability assembled from
/// the `AT+CPBS=?`, `AT+CPBS?`, and `AT+CPBR=?` query commands. Probing never
/// selects a storage (`AT+CPBS="…"`) and never reads or writes entries, so the
/// snapshot only describes what the firmware reports.
struct PhonebookState: Equatable {
    /// Storage type codes advertised by `AT+CPBS=?` (e.g. "SM", "ME", "ON").
    var supportedStorages: [String] = []
    /// Storage the modem session currently has selected, per `AT+CPBS?`.
    var selectedStorage: String?
    /// Filled and total record slots of the selected storage, per `AT+CPBS?`.
    var usedSlots: Int?
    var totalSlots: Int?
    /// Record index range of the selected storage, per `AT+CPBR=?`.
    var recordRange: ClosedRange<Int>?
    /// Maximum number and name field lengths, per `AT+CPBR=?`.
    var maxNumberLength: Int?
    var maxNameLength: Int?
    var lastProbedAt: Date?
    /// Localized reason shown when a probe found no usable phonebook data.
    var lastError: String?

    /// True when at least one query returned usable phonebook data.
    var isSupported: Bool {
        !supportedStorages.isEmpty || selectedStorage != nil || recordRange != nil
    }
}
