import SwiftUI
import SwiftData

// MARK: Plan: deadlines

struct DeadlinesTile: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(filter: #Predicate<Deadline> { !$0.done }, sort: \Deadline.due) private var open: [Deadline]
    @State private var quick = ""
    @State private var noDay = false
    @State private var ticked: Set<PersistentIdentifier> = []
    @State private var editing: Deadline?
    @State private var title = ""
    @State private var course = ""
    @State private var kind = DeadlineKind.assignment
    @State private var when = ""
    @State private var whenAtOpen = ""

    var body: some View {
        Tile {
            HStack {
                TileLabel(text: "Deadlines")
                Spacer()
                Text("Reminders a day and 2 hours before").font(F.label).foregroundStyle(C.muted)
            }
            HStack(spacing: 8) {
                TextField("Physics exam Friday 9am", text: $quick).deckField().onSubmit(add)
                Button("Add", action: add).buttonStyle(.pill).disabled(quick.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if noDay { Text("Add a day too, like Friday 9am or Oct 30.").font(F.label).foregroundStyle(C.warn) }
            if let d = editing { editor(d) }
            if open.isEmpty {
                Text("No deadlines yet. Type one above, like Essay for History next Monday.").font(F.body).foregroundStyle(C.text2)
            }
            ForEach(Array(open.enumerated()), id: \.element.id) { i, d in row(d, divider: i < open.count - 1) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ d: Deadline, divider: Bool) -> some View {
        let late = d.due < .now
        return Row(divider: divider) {
            Button {
                ticked.insert(d.id)
                // Let the check show for a moment before it leaves the list.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { d.done = true; try? context.save() }
            } label: {
                Image(systemName: ticked.contains(d.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ticked.contains(d.id) ? C.lime : C.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(d.title) done")
            Text(d.deadlineKind.label.uppercased()).font(F.mono(10)).foregroundStyle(accent.soft)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(accent.border, lineWidth: 1))
            Text(d.title).font(F.body).lineLimit(1)
            if !d.course.isEmpty { Text(d.course).font(F.label).foregroundStyle(C.text2).lineLimit(1) }
            Spacer()
            Text(late ? "late" : d.due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " " + clock(d.due))
                .font(F.mono(11)).foregroundStyle(late ? C.warn : C.text2)
        }
        .contentShape(Rectangle())
        .onTapGesture { edit(d) }
    }

    private func editor(_ d: Deadline) -> some View {
        let parsed = when == whenAtOpen ? d.due : Deadlines.parse(when, now: .now)?.due
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Title", text: $title).deckField()
                TextField("Course", text: $course).deckField()
            }
            PillPicker(selection: $kind, options: DeadlineKind.allCases.map { ($0.label, $0) })
            HStack(spacing: 8) {
                TextField("When, like Friday 9am", text: $when).deckField()
                Text(parsed.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " " + clock($0) } ?? "Type a day and time")
                    .font(F.mono(11)).foregroundStyle(parsed == nil ? C.warn : C.text2)
            }
            HStack(spacing: 8) {
                Button("Save") { save(d, due: parsed) }.buttonStyle(.pill).disabled(parsed == nil || title.isEmpty)
                Button("Cancel") { editing = nil }.buttonStyle(.pill)
                Spacer()
                Button("Delete") { context.delete(d); try? context.save(); editing = nil }.buttonStyle(.pill)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(C.bg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(C.border, lineWidth: 1))
    }

    private func add() {
        guard !quick.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let p = Deadlines.parse(quick, now: .now) else { noDay = true; return }
        context.insert(Deadline(title: p.title, course: p.course, due: p.due, kind: p.kind))
        try? context.save()
        quick = ""
        noDay = false
    }

    private func edit(_ d: Deadline) {
        editing = d
        (title, course, kind) = (d.title, d.course, d.deadlineKind)
        when = Deadlines.editText(d.due)
        whenAtOpen = when
    }

    private func save(_ d: Deadline, due: Date?) {
        guard let due else { return }
        d.title = title.trimmingCharacters(in: .whitespaces)
        d.course = course.trimmingCharacters(in: .whitespaces)
        d.kind = kind.rawValue
        if due != d.due { d.due = due; d.remindedDay = false; d.remindedHours = false }
        try? context.save()
        editing = nil
    }
}

extension Deadlines {
    /// A date written so the quick-add reader gets it back exactly ("Oct 17, 2026 at 9:00 AM").
    static func editText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return f.string(from: d)
    }
}

// MARK: Plan: timetable

struct TimetableTile: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \ClassSlot.start) private var classes: [ClassSlot]
    @State private var editing: ClassSlot?
    @State private var course = ""
    @State private var room = ""
    @State private var startText = ""
    @State private var endText = ""
    @State private var day = 2
    @State private var color = 0

    private var start: Int? { Timetable.minutes(startText) }
    private var end: Int? { Timetable.minutes(endText) }
    private var valid: Bool { !course.trimmingCharacters(in: .whitespaces).isEmpty && start != nil && end != nil && end! > start! }

    var body: some View {
        Tile {
            HStack {
                TileLabel(text: "Timetable")
                Spacer()
                Text(classes.isEmpty ? "Add your classes and Home shows what's next" : "Click a class to change it")
                    .font(F.label).foregroundStyle(C.muted)
            }
            grid
            form
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var grid: some View {
        let today = Calendar.current.component(.weekday, from: .now)
        return HStack(alignment: .top, spacing: 6) {
            ForEach(Timetable.week, id: \.self) { wd in
                VStack(alignment: .leading, spacing: 4) {
                    Text(Calendar.current.shortWeekdaySymbols[wd - 1]).font(F.label)
                        .foregroundStyle(wd == today ? accent.accent : C.text2)
                    ForEach(classes.filter { $0.weekday == wd }) { block($0) }
                    if !classes.contains(where: { $0.weekday == wd }) {
                        RoundedRectangle(cornerRadius: 4).fill(C.line.opacity(0.5)).frame(height: 30)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func block(_ c: ClassSlot) -> some View {
        let tint = Accent.all[c.color % Accent.all.count].accent
        return HStack(spacing: 4) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.course).font(F.ui(11, medium: true)).lineLimit(1)
                Text(Timetable.time(c.start)).font(F.mono(10)).foregroundStyle(C.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .background(tint.opacity(editing?.id == c.id ? 0.35 : 0.18))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { load(c) }
        .help("\(c.course), \(Timetable.time(c.start))–\(Timetable.time(c.end))\(c.room.isEmpty ? "" : ", \(c.room)")")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Course, like Linear Algebra", text: $course).deckField()
                TextField("Room (optional)", text: $room).deckField().frame(maxWidth: 150)
                TextField("9:00", text: $startText).deckField().frame(width: 64)
                Text("to").font(F.label).foregroundStyle(C.text2)
                TextField("10:30", text: $endText).deckField().frame(width: 64)
            }
            HStack(spacing: 8) {
                PillPicker(selection: $day, options: Timetable.week.map { (Calendar.current.shortWeekdaySymbols[$0 - 1], $0) })
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ForEach(Accent.all.indices, id: \.self) { i in
                        Circle().fill(Accent.all[i].accent).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(C.text, lineWidth: color == i ? 2 : 0))
                            .onTapGesture { color = i }
                            .accessibilityLabel("Colour \(Accent.all[i].id)")
                    }
                }
            }
            HStack(spacing: 8) {
                if (!startText.isEmpty && start == nil) || (!endText.isEmpty && end == nil) {
                    Text("Times look like 9:00 or 2:30pm").font(F.label).foregroundStyle(C.warn)
                } else if let s = start, let e = end, e <= s {
                    Text("The class should end after it starts").font(F.label).foregroundStyle(C.warn)
                }
                Spacer()
                if let c = editing {
                    Button("Delete") { context.delete(c); try? context.save(); clear() }.buttonStyle(.pill)
                    Button("Cancel", action: clear).buttonStyle(.pill)
                }
                Button(editing == nil ? "Add class" : "Save", action: save).buttonStyle(.pill).disabled(!valid)
            }
        }
    }

    private func load(_ c: ClassSlot) {
        editing = c
        (course, room, day, color) = (c.course, c.room, c.weekday, c.color)
        (startText, endText) = (Timetable.time(c.start), Timetable.time(c.end))
    }

    private func clear() {
        editing = nil
        (course, room, startText, endText) = ("", "", "", "")
    }

    private func save() {
        guard valid, let s = start, let e = end else { return }
        let name = course.trimmingCharacters(in: .whitespaces), place = room.trimmingCharacters(in: .whitespaces)
        if let c = editing {
            (c.course, c.room, c.weekday, c.start, c.end, c.color) = (name, place, day, s, e, color)
        } else {
            context.insert(ClassSlot(course: name, weekday: day, start: s, end: e, room: place, color: color))
        }
        try? context.save()
        // Keep the day and colour, so adding the same course on another day is quick.
        editing = nil
        (startText, endText) = ("", "")
    }
}

// MARK: Plan: focus by subject

/// Focus hours per subject as bars; the best subject is lime.
struct SubjectBars: View {
    let sessions: [FocusSession]
    @Environment(\.accent) private var accent

    var body: some View {
        let rows = Array(Subjects.minutes(sessions.map { ($0.subject, $0.minutes) }).prefix(5))
        let best = max(rows.first?.minutes ?? 1, 1)
        if !rows.isEmpty {
            TileLabel(text: "Focus by subject").padding(.top, 6)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                HStack(spacing: 8) {
                    Text(r.name).font(F.label).foregroundStyle(C.text).lineLimit(1).frame(width: 96, alignment: .leading)
                    Bar4(value: Double(r.minutes) / Double(best), color: i == 0 ? C.lime : accent.accent)
                    Text(String(format: "%.1f h", Double(r.minutes) / 60)).font(F.mono(11)).foregroundStyle(C.text2)
                        .frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: Home: next deadline

/// A lime split-flap countdown to the next open deadline, updated each minute.
struct NextDeadlineTile: View {
    @Query(filter: #Predicate<Deadline> { !$0.done }, sort: \Deadline.due) private var open: [Deadline]

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            Tile {
                TileLabel(text: "Next deadline")
                Spacer(minLength: 0)
                if let d = open.first(where: { $0.due > ctx.date }) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(Deadlines.countdown(to: d.due, now: ctx.date).enumerated()), id: \.offset) { _, p in
                            VStack(alignment: .leading, spacing: 3) {
                                SplitFlap(text: p.value, size: 26)
                                Text(p.unit).font(F.mono(10)).foregroundStyle(C.lime.opacity(0.75))
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Deadlines.countdownText(to: d.due, now: ctx.date).lowercased() + " left")
                    Text(d.title).font(F.ui(13, medium: true)).lineLimit(1)
                    Text(d.course.isEmpty ? d.deadlineKind.label : "\(d.course) · \(d.deadlineKind.label)")
                        .font(F.label).foregroundStyle(C.text2).lineLimit(1)
                } else {
                    Text("No deadlines. Add one in Plan.").font(F.body).foregroundStyle(C.text2)
                }
            }
        }
    }
}
