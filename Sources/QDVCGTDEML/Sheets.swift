import SwiftUI
import GTDCore

/// `gtd close <file> with <other>`: pick the email that closed this one.
struct CloseWithSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let recordID: String
    @State private var query = ""
    @State private var chosen: String?

    var body: some View {
        let r = model.record(recordID)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = model.records
            .filter { $0.id != recordID && $0.tracked }
            .filter { q.isEmpty || $0.filename.lowercased().contains(q) || $0.subject.lowercased().contains(q)
                || $0.listCorrespondent.lowercased().contains(q) }
            .sorted { $0.date.epoch > $1.date.epoch }
        VStack(alignment: .leading, spacing: 12) {
            Text("Close With\u{2026}").font(.title2.weight(.semibold))
            if let r {
                Text("Archive \u{201C}\(r.subject)\u{201D}, set its next action to \u{201C}Closed with \u{2026}\u{201D} and stamp ds_archive with today\u{2019}s date.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Filter by subject, correspondent or filename", text: $query)
                .textFieldStyle(.roundedBorder)
            List(candidates, selection: $chosen) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.listCorrespondent).fontWeight(.semibold).lineLimit(1)
                        Spacer()
                        Text(model.dates.list(c.date.date)).foregroundStyle(.secondary).font(.callout)
                    }
                    Text(c.subject).lineLimit(1)
                    Text("\(c.folder.title) \u{00B7} \(c.filename)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(c.id)
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Close Email") {
                    if let chosen {
                        dismiss()
                        model.close(recordID, with: chosen)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}

/// `gtd workflow_autofix`: every proposed stamp, and a single Apply.
struct ReviewDateStampsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let plan = model.autofix
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Date Stamps").font(.title2.weight(.semibold))
            if plan.pendingInput > 0 {
                Label("\(plan.pendingInput) file\(plan.pendingInput == 1 ? " is" : "s are") still in 01-input, so date stamps cannot be fixed yet. Ingest them into Triage first.",
                      systemImage: "tray.and.arrow.down")
                    .fixedSize(horizontal: false, vertical: true)
            } else if !plan.blockers.isEmpty {
                Text("These emails cannot be fixed automatically and must be resolved by hand first. File each into the folder that matches its actual state, then review again. Nothing will be changed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List(plan.blockers) { b in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.filename).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                        Text("[\(b.folder.rawValue)] \(b.reason)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if plan.fixes.isEmpty {
                Label("metadata.csv is already consistent; no changes needed.", systemImage: "checkmark.circle")
                Spacer()
            } else {
                Text("\(plan.fixes.count) stamp\(plan.fixes.count == 1 ? "" : "s") will be written to metadata.csv. If you track the workspace with git, you may want to commit first, so these changes are easy to reverse.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List {
                    ForEach([AutofixFix.Phase.folderConsistency, .dateBackfill], id: \.self) { phase in
                        let group = plan.fixes.filter { $0.phase == phase }
                        if !group.isEmpty {
                            Section("\(phase.title) (\(group.count))") {
                                ForEach(group) { f in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.filename).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                                        Text("[\(f.folder.rawValue)] \(f.field): \(f.old.isEmpty ? "(unset)" : f.old) \u{2192} \(f.new)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                if plan.pendingInput > 0 {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Ingest") {
                        model.ingest()
                        model.beginReviewDateStamps()
                    }
                    .keyboardShortcut(.defaultAction)
                } else if plan.blockers.isEmpty && !plan.fixes.isEmpty {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Apply All") { model.applyAutofix() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}

/// `gtd metadata_check`: what reconciling would drop, and dangling refs.
struct CheckMetadataSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let report: MetadataCheckReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check Metadata").font(.title2.weight(.semibold))
            Text("Reconciling adds a row to metadata.csv for every .eml file that lacks one and removes rows whose file no longer exists. It never moves or renames emails.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                Section("Rows whose file no longer exists (\(report.missingFiles.count))") {
                    if report.missingFiles.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(report.missingFiles, id: \.self) { name in
                        Text(name).font(.body.monospaced())
                    }
                }
                Section("Next actions naming a missing .eml (\(report.danglingRefs.count))") {
                    if report.danglingRefs.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(report.danglingRefs, id: \.self) { ref in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ref.filename).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                            Text("next_action \u{2192} \(ref.reference)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                if !report.missingFiles.isEmpty {
                    Text("Reconciling will drop the rows listed first, including their notes.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reconcile metadata.csv") { model.reconcileMetadata() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
    }
}
