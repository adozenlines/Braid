/*
 Forked from tonyarnold's 'Differ' library to add equality checking.
 
 https://github.com/tonyarnold/Differ
*/

/// A closure used to check whether there the two items are equal (i.e. whether the difference between them would
/// warrant an update). Can return nil to mean that the closure was unable to compare the two items.
typealias ComparisonHandler<T: Collection> = (T.Element, T.Element) -> Bool?

protocol DiffProtocol: Collection {
    associatedtype DiffElementType
    
    var elements: [DiffElementType] { get }
}

struct UndiffableError: Error { }

struct _Diff: DiffProtocol {
    enum Element {
        case insert(at: Int)
        case delete(at: Int)
        case update(at: Int)
    }

    func index(after i: Int) -> Int {
        return i + 1
    }
    
    var elements: [_Diff.Element]
    
    init(elements: [_Diff.Element]) {
        self.elements = elements
    }
}

extension _Diff.Element {
    init?(trace: Trace) {
        switch trace.type() {
        case .insertion:
            self = .insert(at: trace.from.y)
        case .deletion:
            self = .delete(at: trace.from.x)
        case .matchPoint:
            return nil
        }
    }
    
    func at() -> Int {
        switch self {
        case let .delete(at):
            return at
        case let .insert(at):
            return at
        case let .update(at):
            return at
        }
    }
}

struct Point: Hashable {
    let x: Int
    let y: Int
}

/// A data structure representing single trace produced by the diff algorithm. See the [paper](http://www.xmailserver.org/diff2.pdf) for more information on traces.
struct Trace: Hashable {
    let from: Point
    let to: Point
    let D: Int
}

enum TraceType {
    case insertion
    case deletion
    case matchPoint
}

extension Trace {
    func type() -> TraceType {
        if from.x + 1 == to.x && from.y + 1 == to.y {
            return .matchPoint
        } else if from.y < to.y {
            return .insertion
        } else {
            return .deletion
        }
    }
    
    func k() -> Int {
        return from.x - from.y
    }
}

extension Array {
    func value(at index: Index) -> Element? {
        if index < 0 || index >= count {
            return nil
        }
        return self[index]
    }
}

struct TraceStep {
    let D: Int
    let k: Int
    let previousX: Int?
    let nextX: Int?
}

extension Collection where Index == Int {
    /**
     Creates a diff between the callee and `other` collection.
     - complexity: O((N+M)*D)
     - parameters:
     - other: a collection to compare the calee to
     - isSame: a closure that determines whether the two items are meant to represent the same item (i.e. 'identity')
     - isEqual: a closure that determines whether the two items (deemed to represent the same item) are 'equal' (i.e.
        whether the second instance of the item has any changes from the first that would warrant a cell update)
     - returns: a Diff between the callee and `other` collection
     */
    func diff(
        _ other: Self,
        isSame: ComparisonHandler<Self>,
        isEqual: ComparisonHandler<Self>)
        throws -> _Diff
    {
        let diffPath = try outputDiffPathTraces(
            to: other,
            isSame: isSame)
        return _Diff(elements:
            diffPath
                .map { trace -> _Diff.Element? in
                    if let change = _Diff.Element(trace: trace) {
                        return change
                    } else if isEqual(self[trace.from.x], other[trace.from.y]) == false {
                        return .update(at: trace.from.x)
                    }
                    return nil
                }
                .compactMap { $0 }
        )
    }
    
    /**
     Generates all traces required to create an output diff. See the [paper](http://www.xmailserver.org/diff2.pdf) for
     more information on traces.
    
     - parameter to: other collection
     - parameter isSame: a closure that determines whether the two items are meant to represent the same item (i.e.
        'identity')
     - returns: all traces required to create an output diff
    */
    func diffTraces(to: Self, isSame: ComparisonHandler<Self>) throws -> [Trace] {
        if count == 0 && to.count == 0 {
            return []
        } else if count == 0 {
            return tracesForInsertions(to: to)
        } else if to.count == 0 {
            return tracesForDeletions()
        } else {
            return try myersDiffTraces(to: to, isSame: isSame)
        }
    }
    
    /// Returns the traces which mark the shortest diff path.
    func outputDiffPathTraces(to: Self, isSame: ComparisonHandler<Self>) throws -> [Trace] {
        let traces = try diffTraces(to: to, isSame: isSame)
        return findPath(
            traces,
            n: Int(count),
            m: Int(to.count)
        )
    }
    
    fileprivate func tracesForDeletions() -> [Trace] {
        var traces = [Trace]()
        for index in 0 ..< Int(count) {
            let intIndex = Int(index)
            traces.append(Trace(from: Point(x: Int(intIndex), y: 0), to: Point(x: Int(intIndex) + 1, y: 0), D: 0))
        }
        return traces
    }
    
    fileprivate func tracesForInsertions(to: Self) -> [Trace] {
        var traces = [Trace]()
        for index in 0 ..< Int(to.count) {
            let intIndex = Int(index)
            traces.append(Trace(from: Point(x: 0, y: Int(intIndex)), to: Point(x: 0, y: Int(intIndex) + 1), D: 0))
        }
        return traces
    }
    
    fileprivate func myersDiffTraces(to: Self, isSame: (Element, Element) -> Bool?) throws -> [Trace] {
        // fromCount is N, N is the number of from array
        let fromCount = Int(count)
        // toCount is M, M is the number of to array
        let toCount = Int(to.count)
        var traces = Array<Trace>()
        
        let max = fromCount + toCount // this is arbitrary, maximum difference between from and to. N+M assures that this algorithm always finds from diff
        
        var vertices = Array(repeating: -1, count: max + 1) // from [0...N+M], it is -M...N in the whitepaper
        vertices[toCount + 1] = 0
        
        // D-patch: numberOfDifferences is D
        for numberOfDifferences in 0 ... max {
            for k in stride(from: (-numberOfDifferences), through: numberOfDifferences, by: 2) {
                
                guard k >= -toCount && k <= fromCount else {
                    continue
                }
                
                let index = k + toCount
                let traceStep = TraceStep(D: numberOfDifferences, k: k, previousX: vertices.value(at: index - 1), nextX: vertices.value(at: index + 1))
                if let trace = bound(trace: nextTrace(traceStep), maxX: fromCount, maxY: toCount) {
                    var x = trace.to.x
                    var y = trace.to.y
                    
                    traces.append(trace)
                    
                    // keep going as long as they match on diagonal k
                    while x >= 0 && y >= 0 && x < fromCount && y < toCount {
                        let targetItem = to.itemOnStartIndex(advancedBy: y)
                        let baseItem = itemOnStartIndex(advancedBy: x)
                        let _isSame = isSame(baseItem, targetItem)
                        if _isSame == true {
                            x += 1
                            y += 1
                            traces.append(Trace(from: Point(x: x - 1, y: y - 1), to: Point(x: x, y: y), D: numberOfDifferences))
                        } else if _isSame == nil {
                            throw UndiffableError()
                        } else {
                            break
                        }
                    }
                    
                    vertices[index] = x
                    
                    if x >= fromCount && y >= toCount {
                        return traces
                    }
                }
            }
        }
        return []
    }
    
    fileprivate func bound(trace: Trace, maxX: Int, maxY: Int) -> Trace? {
        guard trace.to.x <= maxX && trace.to.y <= maxY else {
            return nil
        }
        return trace
    }
    
    fileprivate func nextTrace(_ traceStep: TraceStep) -> Trace {
        let traceType = nextTraceType(traceStep)
        let k = traceStep.k
        let D = traceStep.D
        
        if traceType == .insertion {
            let x = traceStep.nextX ?? -1
            return Trace(from: Point(x: x, y: x - k - 1), to: Point(x: x, y: x - k), D: D)
        } else {
            let x = (traceStep.previousX ?? 0) + 1
            return Trace(from: Point(x: x - 1, y: x - k), to: Point(x: x, y: x - k), D: D)
        }
    }
    
    fileprivate func nextTraceType(_ traceStep: TraceStep) -> TraceType {
        let D = traceStep.D
        let k = traceStep.k
        let previousX = traceStep.previousX
        let nextX = traceStep.nextX
        
        if k == -D {
            return .insertion
        } else if k != D {
            if let previousX = previousX, let nextX = nextX, previousX < nextX {
                return .insertion
            }
            return .deletion
        } else {
            return .deletion
        }
    }
    
    fileprivate func findPath(_ traces: [Trace], n: Int, m: Int) -> [Trace] {
        guard traces.count > 0 else {
            return []
        }
        
        var array = [Trace]()
        var item = traces.last!
        array.append(item)
        
        if item.from != Point(x: 0, y: 0) {
            for trace in traces.reversed() {
                if trace.to.x == item.from.x && trace.to.y == item.from.y {
                    array.insert(trace, at: 0)
                    item = trace
                    
                    if trace.from == Point(x: 0, y: 0) {
                        break
                    }
                }
            }
        }
        return array
    }
}

extension DiffProtocol {
    typealias IndexType = Array<DiffElementType>.Index
    
    var startIndex: IndexType {
        return elements.startIndex
    }
    
    var endIndex: IndexType {
        return elements.endIndex
    }
    
    subscript(i: IndexType) -> DiffElementType {
        return elements[i]
    }
}

extension _Diff {
    init(traces: [Trace]) {
        elements = traces.compactMap { _Diff.Element(trace: $0) }
    }
}

extension _Diff.Element: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case let .delete(at):
            return "D(r:\(at))"
        case let .insert(at):
            return "I(r:\(at))"
        case let .update(at):
            return "U(r:\(at))"
        }
    }
}

extension _Diff: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: _Diff.Element...) {
        self.elements = elements
    }
}
