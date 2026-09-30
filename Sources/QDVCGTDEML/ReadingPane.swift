import SwiftUI
import GTDCore

/// Pane 3: the selected email.
struct ReadingPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let r = model.selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PillRow(record: r)
                    Text(r.subject)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    AnnotationsCard(record: r)
                        .id("annotations-\(r.id)")
                    WorkflowTrail(record: r)
                    Divider()
                    ThreadView(record: r)
                        .id("thread-\(r.id)")
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.selection.count > 1 {
            MultipleSelectionView()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No Email Selected").font(.title3).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MultipleSelectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.selectedRecords.map(\.id)
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("\(ids.count) Emails Selected").font(.title3)
            HStack {
                Menu("Move To") {
                    ForEach(Folder.allCases.filter { $0 != .input }) { folder in
                        Button(folder.title) { model.move(ids, to: folder) }
                            .disabled(!model.canMove(ids, to: folder))
                    }
                }
                .fixedSize()
                Button("Archive") { model.move(ids, to: .archive) }
                    .disabled(!model.canMove(ids, to: .archive))
                Button("Pin / Unpin") { model.togglePin(ids) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Age, folder, account, status and due date at a glance.
struct PillRow: View {
    @Environment(AppModel.self) private var model
    let record: EmailRecord

    var body: some View {
        let r = record
        HStack(spacing: 6) {
            if let age = r.ageDays, let cls = r.ageClass {
                Pill(text: "\(age) day\(age == 1 ? "" : "s")", color: cls.color, symbol: "clock")
            }
            Pill(text: r.folder.title, color: .accentColor, symbol: r.folder.symbol)
            if let account = r.account {
                Pill(text: account.displayName, color: account.color, symbol: "person.crop.circle")
            }
            if !r.status.isEmpty {
                Pill(text: r.status.capitalizedFirst, color: r.status == "weird" ? .orange : .secondary,
                     symbol: r.status == "resolved" ? "checkmark.circle" : "circle.dashed")
            }
            if r.isPinned { Pill(text: "Pinned", color: .pink, symbol: "pin.fill") }
            if !r.dueDate.isEmpty {
                Pill(text: "Due \(model.dates.isoDay(r.dueDate))",
                     color: r.isOverdue(today: model.today) ? .red : .secondary, symbol: "calendar")
            }
            Spacer(minLength: 0)
        }
    }
}

struct Pill: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

/// The GTD annotations, shown read-only with an Edit button that turns the
/// card into a form; nothing is written until Save.
struct AnnotationsCard: View {
    @Environment(AppModel.self) private var model
    let record: EmailRecord

    @State private var nextAction = ""
    @State private var project = ""
    @State private var dueDate = ""
    @State private var flags = ""
    @State private var notes = ""
    @State private var pickingDate = false
    @State private var pickedDate = Date()

    private var editing: Bool { model.editingAnnotationsID == record.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Annotations").font(.headline)
                Spacer()
                if editing {
                    Button("Cancel") { model.editingAnnotationsID = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Edit") { begin() }
                        .disabled(model.annotationsRefusal(record) != nil)
                        .help(model.annotationsRefusal(record) ?? "Edit the annotations (\u{2318}E)")
                }
            }
            if editing { form } else { summary }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .onAppear { if editing { load() } }
        .onChange(of: editing) { _, now in if now { load() } }
    }

    private var summary: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            field("Next action", record.nextAction, placeholder: "No next action")
            field("Project", record.project)
            field("Due", record.dueDate.isEmpty ? "" : model.dates.isoDay(record.dueDate))
            field("Flags", record.flags.joined(separator: ", "))
            field("Notes", record.notes)
            if !record.ref.isEmpty { field("Message ref", record.ref) }
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String, placeholder: String = "\u{2014}") -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value.isEmpty ? placeholder : value)
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Next action").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField("What is the next action?", text: $nextAction)
            }
            GridRow {
                Text("Project").foregroundStyle(.secondary)
                HStack {
                    TextField("Project", text: $project)
                    Menu {
                        ForEach(model.projects, id: \.self) { name in
                            Button(name) { project = name }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.projects.isEmpty)
                    .help("Choose an existing project")
                }
            }
            GridRow {
                Text("Due").foregroundStyle(.secondary)
                HStack {
                    TextField("yyyy-mm-dd or free text", text: $dueDate)
                    Button {
                        pickedDate = dateFromDue() ?? Date()
                        pickingDate = true
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .help("Pick a date")
                    .popover(isPresented: $pickingDate) {
                        VStack {
                            DatePicker("Due date", selection: $pickedDate, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .labelsHidden()
                            HStack {
                                Button("Clear") {
                                    dueDate = ""
                                    pickingDate = false
                                }
                                Spacer()
                                Button("Set") {
                                    dueDate = Day.today(now: pickedDate).iso
                                    pickingDate = false
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding()
                    }
                }
            }
            if !dueDate.trimmingCharacters(in: .whitespaces).isEmpty && !Rules.isISODate(dueDate) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("Not a yyyy-mm-dd date: it will be saved, but cannot be compared with today.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            GridRow {
                Text("Flags").foregroundStyle(.secondary)
                TextField("Space-separated, e.g. pinned", text: $flags)
            }
            GridRow {
                Text("Notes").foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 70, maxHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }
        }
    }

    private func dateFromDue() -> Date? {
        guard let d = Day(iso: dueDate.trimmingCharacters(in: .whitespaces)) else { return nil }
        var c = DateComponents()
        c.year = d.year
        c.month = d.month
        c.day = d.day
        c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)
    }

    private func begin() { model.beginEdit(record.id) }

    private func load() {
        nextAction = record.row["next_action"] ?? ""
        project = record.row["project"] ?? ""
        dueDate = record.row["due_date"] ?? ""
        flags = record.row["flags"] ?? ""
        notes = record.row["general_notes"] ?? ""
    }

    private func save() {
        model.saveAnnotations(record.id, ["next_action": nextAction, "project": project, "due_date": dueDate,
                                          "flags": flags, "general_notes": notes])
    }
}

/// The ds_* stamps in order, plus the response-time metrics.
struct WorkflowTrail: View {
    @Environment(AppModel.self) private var model
    let record: EmailRecord
    @State private var showMetrics = false

    static let metricNames = [("ttS", "Time to start (arrival \u{2192} triage)"),
                              ("Td", "Time to decide (triage \u{2192} actionable)"),
                              ("Wd", "Work duration (actionable \u{2192} resolved)"),
                              ("tttR", "Total time to resolve")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workflow").font(.headline)
            if record.stamps.isEmpty {
                Text(record.folder == .input ? "Not ingested yet." : "No date stamps recorded.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(record.stamps.enumerated()), id: \.offset) { index, stamp in
                        if index > 0 {
                            Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stamp.label).font(.caption.weight(.semibold))
                            Text(model.dates.isoDay(stamp.date)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !record.metrics.isEmpty {
                DisclosureGroup("Metrics", isExpanded: $showMetrics) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(WorkflowTrail.metricNames, id: \.0) { key, label in
                            if let days = record.metrics[key] {
                                GridRow {
                                    Text(key).font(.caption.monospaced())
                                    Text(label).font(.caption).foregroundStyle(.secondary)
                                    Text("\(days) d").font(.caption).monospacedDigit()
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            if record.status == "weird" {
                Label("The date progression is inconsistent, so this email is left out of the performance figures.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// The email and the messages quoted in it, one block each.
struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let record: EmailRecord
    @State private var collapsed: Set<Int> = []
    @State private var initialised = false

    var body: some View {
        let p = record.parsed
        VStack(alignment: .leading, spacing: 12) {
            if let error = p.error {
                Label("This file could not be read: \(error)", systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
            }
            HeaderGrid(rows: [("From", p.fromText), ("To", p.toText), ("Cc", p.ccText), ("Bcc", p.bccText),
                              ("Date", p.date.map { model.dates.full($0.date) } ?? "(no date)"),
                              ("File", record.filename)])
            if !p.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(p.attachments.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "paperclip").font(.callout)
                    }
                }
            }
            if p.thread.isEmpty && p.error == nil {
                Text("(no text)").foregroundStyle(.tertiary)
            }
            ForEach(Array(p.thread.enumerated()), id: \.offset) { index, message in
                block(index, message)
                    .padding(.leading, CGFloat(message.indent) * 14)
            }
        }
        .onAppear {
            guard !initialised else { return }
            initialised = true
            // Newest two messages open, older quoted ones folded.
            collapsed = Set(p.thread.indices.filter { $0 >= 2 })
        }
    }

    @ViewBuilder
    private func block(_ index: Int, _ m: ThreadMessage) -> some View {
        let isOpen = Binding(get: { !collapsed.contains(index) },
                             set: { open in if open { collapsed.remove(index) } else { collapsed.insert(index) } })
        if index == 0 && !m.hasHeaders {
            Text(m.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DisclosureGroup(isExpanded: isOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    HeaderGrid(rows: [("From", m.from ?? ""), ("To", m.to ?? ""), ("Cc", m.cc ?? ""),
                                      ("Subject", m.subject ?? ""),
                                      ("Date", m.date.map { model.dates.quoted(m.dateParts, raw: $0) } ?? "")])
                    Text(m.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
            } label: {
                Text(summary(m))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
    }

    private func summary(_ m: ThreadMessage) -> String {
        let who = m.from.map(EmailRecord.displayName) ?? "Quoted message"
        if let date = m.date { return "\(who) \u{2014} \(model.dates.quoted(m.dateParts, raw: date))" }
        return who
    }
}

struct HeaderGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if !row.1.isEmpty {
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(row.1).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .font(.callout)
    }
}
