enum InsertKind: Equatable, Sendable {
    case i
    case a
    case I
    case A
    case o
    case O
    case s
    case change
}

enum OperatorKind: Equatable, Sendable {
    case delete
    case change
    case yank
    case indent
    case unindent

    init?(character: Character) {
        switch character {
        case "d": self = .delete
        case "c": self = .change
        case "y": self = .yank
        case ">": self = .indent
        case "<": self = .unindent
        default: return nil
        }
    }
}

struct FindSpec: Equatable {
    var kind: FindKind
    var target: Character
}

enum RepeatTarget: Equatable {
    case motion(MotionKind, count: Int, find: FindSpec?)
    case textObject(TextObjectKind)
    case line
    case characterCount(Int)
    case visualLines(Int)
}

enum Repeatable: Equatable {
    case insert(kind: InsertKind, text: String, count: Int)
    case operate(OperatorKind, count: Int, target: RepeatTarget, inserted: String?)
    case replace(count: Int, Character)
    case toggleCase(count: Int)
    case join(count: Int)
    case put(after: Bool, count: Int)
}
