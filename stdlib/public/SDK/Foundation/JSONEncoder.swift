//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// JSON Encoder
//===----------------------------------------------------------------------===//

/// `JSONEncoder` facilitates the encoding of `Encodable` values into JSON.
open class JSONEncoder {
    // MARK: Options

    /// The formatting of the output JSON data.
    public struct OutputFormatting : OptionSet {
        /// The format's default value.
        public let rawValue: UInt

        /// Creates an OutputFormatting value with the given raw value.
        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        /// Produce human-readable JSON with indented output.
        public static let prettyPrinted = OutputFormatting(rawValue: 1 << 0)

        /// Produce JSON with dictionary keys sorted in lexicographic order.
        @available(OSX 10.13, iOS 11.0, watchOS 4.0, tvOS 11.0, *)
        public static let sortedKeys    = OutputFormatting(rawValue: 1 << 1)
    }

    /// The strategy to use for encoding `Date` values.
    public enum DateEncodingStrategy {
        /// Defer to `Date` for choosing an encoding. This is the default strategy.
        case deferredToDate

        /// Encode the `Date` as a UNIX timestamp (as a JSON number).
        case secondsSince1970

        /// Encode the `Date` as UNIX millisecond timestamp (as a JSON number).
        case millisecondsSince1970

        /// Encode the `Date` as an ISO-8601-formatted string (in RFC 3339 format).
        @available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
        case iso8601

        /// Encode the `Date` as a string formatted by the given formatter.
        case formatted(DateFormatter)

        /// Encode the `Date` as a custom value encoded by the given closure.
        ///
        /// If the closure fails to encode a value into the given encoder, the encoder will encode an empty automatic container in its place.
        case custom((Date, Encoder) throws -> Void)
    }

    /// The strategy to use for encoding `Data` values.
    public enum DataEncodingStrategy {
        /// Encoded the `Data` as a Base64-encoded string. This is the default strategy.
        case base64Encode

        /// Encode the `Data` as a custom value encoded by the given closure.
        ///
        /// If the closure fails to encode a value into the given encoder, the encoder will encode an empty automatic container in its place.
        case custom((Data, Encoder) throws -> Void)
    }

    /// The strategy to use for non-JSON-conforming floating-point values (IEEE 754 infinity and NaN).
    public enum NonConformingFloatEncodingStrategy {
        /// Throw upon encountering non-conforming values. This is the default strategy.
        case `throw`

        /// Encode the values using the given representation strings.
        case convertToString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// The output format to produce. Defaults to `[]`.
    open var outputFormatting: OutputFormatting = []

    /// The strategy to use in encoding dates. Defaults to `.deferredToDate`.
    open var dateEncodingStrategy: DateEncodingStrategy = .deferredToDate

    /// The strategy to use in encoding binary data. Defaults to `.base64Encode`.
    open var dataEncodingStrategy: DataEncodingStrategy = .base64Encode

    /// The strategy to use in encoding non-conforming numbers. Defaults to `.throw`.
    open var nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy = .throw

    /// Contextual user-provided information for use during encoding.
    open var userInfo: [CodingUserInfoKey : Any] = [:]

    /// Options set on the top-level encoder to pass down the encoding hierarchy.
    fileprivate struct _Options {
        let dateEncodingStrategy: DateEncodingStrategy
        let dataEncodingStrategy: DataEncodingStrategy
        let nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy
        let userInfo: [CodingUserInfoKey : Any]
    }

    /// The options set on the top-level encoder.
    fileprivate var options: _Options {
        return _Options(dateEncodingStrategy: dateEncodingStrategy,
                        dataEncodingStrategy: dataEncodingStrategy,
                        nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy,
                        userInfo: userInfo)
    }

    // MARK: - Constructing a JSON Encoder

    /// Initializes `self` with default strategies.
    public init() {}

    // MARK: - Encoding Values

    /// Encodes the given top-level value and returns its JSON representation.
    ///
    /// - parameter value: The value to encode.
    /// - returns: A new `Data` value containing the encoded JSON data.
    /// - throws: `EncodingError.invalidValue` if a non-comforming floating-point value is encountered during encoding, and the encoding strategy is `.throw`.
    /// - throws: An error if any value throws an error during encoding.
    open func encode<T : Encodable>(_ value: T) throws -> Data {
        let encoder = _JSONEncoder(options: self.options)
        try value.encode(to: encoder)

        guard encoder.storage.count > 0 else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Top-level \(T.self) did not encode any values."))
        }

        let topLevel = encoder.storage.popContainer()
        if topLevel is NSNull {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Top-level \(T.self) encoded as null JSON fragment."))
        } else if topLevel is NSNumber {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Top-level \(T.self) encoded as number JSON fragment."))
        } else if topLevel is NSString {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Top-level \(T.self) encoded as string JSON fragment."))
        }

        var writingOptions = JSONSerialization.WritingOptions(rawValue: self.outputFormatting.rawValue)
        return try JSONSerialization.data(withJSONObject: topLevel, options: writingOptions)
    }
}

// MARK: - _JSONEncoder

fileprivate class _JSONEncoder : Encoder {
    // MARK: Properties

    /// The encoder's storage.
    var storage: _JSONEncodingStorage

    /// Options set on the top-level encoder.
    let options: JSONEncoder._Options

    /// The path to the current point in encoding.
    var codingPath: [CodingKey?]

    /// Contextual user-provided information for use during encoding.
    var userInfo: [CodingUserInfoKey : Any] {
        return self.options.userInfo
    }

    // MARK: - Initialization

    /// Initializes `self` with the given top-level encoder options.
    init(options: JSONEncoder._Options, codingPath: [CodingKey?] = []) {
        self.options = options
        self.storage = _JSONEncodingStorage()
        self.codingPath = codingPath
    }

    // MARK: - Coding Path Operations

    /// Performs the given closure with the given key pushed onto the end of the current coding path.
    ///
    /// - parameter key: The key to push. May be nil for unkeyed containers.
    /// - parameter work: The work to perform with the key in the path.
    func with<T>(pushedKey key: CodingKey?, _ work: () throws -> T) rethrows -> T {
        self.codingPath.append(key)
        let ret: T = try work()
        self.codingPath.removeLast()
        return ret
    }

    /// Returns whether a new element can be encoded at this coding path.
    ///
    /// `true` if an element has not yet been encoded at this coding path; `false` otherwise.
    var canEncodeNewElement: Bool {
        // Every time a new value gets encoded, the key it's encoded for is pushed onto the coding path (even if it's a nil key from an unkeyed container).
        // At the same time, every time a container is requested, a new value gets pushed onto the storage stack.
        // If there are more values on the storage stack than on the coding path, it means the value is requesting more than one container, which violates the precondition.
        //
        // This means that anytime something that can request a new container goes onto the stack, we MUST push a key onto the coding path.
        // Things which will not request containers do not need to have the coding path extended for them (but it doesn't matter if it is, because they will not reach here).
        return self.storage.count == self.codingPath.count
    }

    /// Asserts that a new container can be requested at this coding path.
    /// `preconditionFailure()`s if one cannot be requested.
    func assertCanRequestNewContainer() {
        guard self.canEncodeNewElement else {
            let previousContainerType: String
            if self.storage.containers.last is NSDictionary {
                previousContainerType = "keyed"
            } else if self.storage.containers.last is NSArray {
                previousContainerType = "unkeyed"
            } else {
                previousContainerType = "single value"
            }

            preconditionFailure("Attempt to encode with new container when already encoded with \(previousContainerType) container.")
        }
    }

    // MARK: - Encoder Methods
    func container<Key>(keyedBy: Key.Type) -> KeyedEncodingContainer<Key> {
        assertCanRequestNewContainer()
        let topContainer = self.storage.pushKeyedContainer()
        let container = _JSONKeyedEncodingContainer<Key>(referencing: self, codingPath: self.codingPath, wrapping: topContainer)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        assertCanRequestNewContainer()
        let topContainer = self.storage.pushUnkeyedContainer()
        return _JSONUnkeyedEncodingContainer(referencing: self, codingPath: self.codingPath, wrapping: topContainer)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        assertCanRequestNewContainer()
        return self
    }
}

// MARK: - Encoding Storage and Containers

fileprivate struct _JSONEncodingStorage {
    // MARK: Properties

    /// The container stack.
    /// Elements may be any one of the JSON types (NSNull, NSNumber, NSString, NSArray, NSDictionary).
    private(set) var containers: [NSObject] = []

    // MARK: - Initialization

    /// Initializes `self` with no containers.
    init() {}

    // MARK: - Modifying the Stack

    var count: Int {
        return self.containers.count
    }

    mutating func pushKeyedContainer() -> NSMutableDictionary {
        let dictionary = NSMutableDictionary()
        self.containers.append(dictionary)
        return dictionary
    }

    mutating func pushUnkeyedContainer() -> NSMutableArray {
        let array = NSMutableArray()
        self.containers.append(array)
        return array
    }

    mutating func push(container: NSObject) {
        self.containers.append(container)
    }

    mutating func popContainer() -> NSObject {
        precondition(self.containers.count > 0, "Empty container stack.")
        return self.containers.popLast()!
    }
}

// MARK: - Encoding Containers

fileprivate struct _JSONKeyedEncodingContainer<K : CodingKey> : KeyedEncodingContainerProtocol {
    typealias Key = K

    // MARK: Properties

    /// A reference to the encoder we're writing to.
    let encoder: _JSONEncoder

    /// A reference to the container we're writing to.
    let container: NSMutableDictionary

    /// The path of coding keys taken to get to this point in encoding.
    var codingPath: [CodingKey?]

    // MARK: - Initialization

    /// Initializes `self` with the given references.
    init(referencing encoder: _JSONEncoder, codingPath: [CodingKey?], wrapping container: NSMutableDictionary) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.container = container
    }

    // MARK: - Coding Path Operations

    /// Performs the given closure with the given key pushed onto the end of the current coding path.
    ///
    /// - parameter key: The key to push. May be nil for unkeyed containers.
    /// - parameter work: The work to perform with the key in the path.
    mutating func with<T>(pushedKey key: CodingKey?, _ work: () throws -> T) rethrows -> T {
        self.codingPath.append(key)
        let ret: T = try work()
        self.codingPath.removeLast()
        return ret
    }

    // MARK: - KeyedEncodingContainerProtocol Methods

    mutating func encode(_ value: Bool, forKey key: Key)   throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: Int, forKey key: Key)    throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: Int8, forKey key: Key)   throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: Int16, forKey key: Key)  throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: Int32, forKey key: Key)  throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: Int64, forKey key: Key)  throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: UInt, forKey key: Key)   throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: UInt8, forKey key: Key)  throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { self.container[key.stringValue] = self.encoder.box(value) }
    mutating func encode(_ value: String, forKey key: Key) throws { self.container[key.stringValue] = self.encoder.box(value) }

    mutating func encode(_ value: Float, forKey key: Key)  throws {
        // Since the float may be invalid and throw, the coding path needs to contain this key.
        try self.encoder.with(pushedKey: key) {
            self.container[key.stringValue] = try self.encoder.box(value)
        }
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        // Since the double may be invalid and throw, the coding path needs to contain this key.
        try self.encoder.with(pushedKey: key) {
            self.container[key.stringValue] = try self.encoder.box(value)
        }
    }

    mutating func encode<T : Encodable>(_ value: T, forKey key: Key) throws {
        try self.encoder.with(pushedKey: key) {
            self.container[key.stringValue] = try self.encoder.box(value)
        }
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let dictionary = NSMutableDictionary()
        self.container[key.stringValue] = dictionary

        return self.with(pushedKey: key) {
            let container = _JSONKeyedEncodingContainer<NestedKey>(referencing: self.encoder, codingPath: self.codingPath, wrapping: dictionary)
            return KeyedEncodingContainer(container)
        }
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let array = NSMutableArray()
        self.container[key.stringValue] = array

        return self.with(pushedKey: key) {
            return _JSONUnkeyedEncodingContainer(referencing: self.encoder, codingPath: self.codingPath, wrapping: array)
        }
    }

    mutating func superEncoder() -> Encoder {
        return _JSONReferencingEncoder(referencing: self.encoder, at: _JSONSuperKey.super, wrapping: self.container)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        return _JSONReferencingEncoder(referencing: self.encoder, at: key, wrapping: self.container)
    }
}

fileprivate struct _JSONUnkeyedEncodingContainer : UnkeyedEncodingContainer {
    // MARK: Properties

    /// A reference to the encoder we're writing to.
    let encoder: _JSONEncoder

    /// A reference to the container we're writing to.
    let container: NSMutableArray

    /// The path of coding keys taken to get to this point in encoding.
    var codingPath: [CodingKey?]

    // MARK: - Initialization

    /// Initializes `self` with the given references.
    init(referencing encoder: _JSONEncoder, codingPath: [CodingKey?], wrapping container: NSMutableArray) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.container = container
    }

    // MARK: - Coding Path Operations

    /// Performs the given closure with the given key pushed onto the end of the current coding path.
    ///
    /// - parameter key: The key to push. May be nil for unkeyed containers.
    /// - parameter work: The work to perform with the key in the path.
    mutating func with<T>(pushedKey key: CodingKey?, _ work: () throws -> T) rethrows -> T {
        self.codingPath.append(key)
        let ret: T = try work()
        self.codingPath.removeLast()
        return ret
    }

    // MARK: - UnkeyedEncodingContainer Methods

    mutating func encode(_ value: Bool)   throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: Int)    throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: Int8)   throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: Int16)  throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: Int32)  throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: Int64)  throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: UInt)   throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: UInt8)  throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: UInt16) throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: UInt32) throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: UInt64) throws { self.container.add(self.encoder.box(value)) }
    mutating func encode(_ value: String) throws { self.container.add(self.encoder.box(value)) }

    mutating func encode(_ value: Float)  throws {
        // Since the float may be invalid and throw, the coding path needs to contain this key.
        try self.encoder.with(pushedKey: nil) {
            self.container.add(try self.encoder.box(value))
        }
    }

    mutating func encode(_ value: Double) throws {
        // Since the double may be invalid and throw, the coding path needs to contain this key.
        try self.encoder.with(pushedKey: nil) {
            self.container.add(try self.encoder.box(value))
        }
    }

    mutating func encode<T : Encodable>(_ value: T) throws {
        try self.encoder.with(pushedKey: nil) {
            self.container.add(try self.encoder.box(value))
        }
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let dictionary = NSMutableDictionary()
        self.container.add(dictionary)

        return self.with(pushedKey: nil) {
            let container = _JSONKeyedEncodingContainer<NestedKey>(referencing: self.encoder, codingPath: self.codingPath, wrapping: dictionary)
            return KeyedEncodingContainer(container)
        }
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let array = NSMutableArray()
        self.container.add(array)

        return self.with(pushedKey: nil) {
            return _JSONUnkeyedEncodingContainer(referencing: self.encoder, codingPath: self.codingPath, wrapping: array)
        }
    }

    mutating func superEncoder() -> Encoder {
        return _JSONReferencingEncoder(referencing: self.encoder, at: self.container.count, wrapping: self.container)
    }
}

extension _JSONEncoder : SingleValueEncodingContainer {
    // MARK: - Utility Methods

    /// Asserts that a single value can be encoded at the current coding path (i.e. that one has not already been encoded through this container).
    /// `preconditionFailure()`s if one cannot be encoded.
    ///
    /// This is similar to assertCanRequestNewContainer above.
    func assertCanEncodeSingleValue() {
        guard self.canEncodeNewElement else {
            let previousContainerType: String
            if self.storage.containers.last is NSDictionary {
                previousContainerType = "keyed"
            } else if self.storage.containers.last is NSArray {
                previousContainerType = "unkeyed"
            } else {
                preconditionFailure("Attempt to encode multiple values in a single value container.")
            }

            preconditionFailure("Attempt to encode with new container when already encoded with \(previousContainerType) container.")
        }
    }

    // MARK: - SingleValueEncodingContainer Methods

    func encodeNil() throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: NSNull())
    }

    func encode(_ value: Bool) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: Int) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: Int8) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: Int16) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: Int32) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: Int64) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: UInt) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: UInt8) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: UInt16) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: UInt32) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: UInt64) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: String) throws {
        assertCanEncodeSingleValue()
        self.storage.push(container: box(value))
    }

    func encode(_ value: Float) throws {
        assertCanEncodeSingleValue()
        try self.storage.push(container: box(value))
    }

    func encode(_ value: Double) throws {
        assertCanEncodeSingleValue()
        try self.storage.push(container: box(value))
    }

    func encode<T : Encodable>(_ value: T) throws {
        assertCanEncodeSingleValue()
        try self.storage.push(container: box(value))
    }
}

// MARK: - Concrete Value Representations

extension _JSONEncoder {
    /// Returns the given value boxed in a container appropriate for pushing onto the container stack.
    fileprivate func box(_ value: Bool)   -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: Int)    -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: Int8)   -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: Int16)  -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: Int32)  -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: Int64)  -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: UInt)   -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: UInt8)  -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: UInt16) -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: UInt32) -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: UInt64) -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: String) -> NSObject { return NSString(string: value) }

    fileprivate func box(_ float: Float) throws -> NSObject {
        guard !float.isInfinite && !float.isNaN else {
            guard case let .convertToString(positiveInfinity: posInfString,
                                            negativeInfinity: negInfString,
                                            nan: nanString) = self.options.nonConformingFloatEncodingStrategy else {
                throw EncodingError._invalidFloatingPointValue(float, at: codingPath)
            }

            if float == Float.infinity {
                return NSString(string: posInfString)
            } else if float == -Float.infinity {
                return NSString(string: negInfString)
            } else {
                return NSString(string: nanString)
            }
        }

        return NSNumber(value: float)
    }

    fileprivate func box(_ double: Double) throws -> NSObject {
        guard !double.isInfinite && !double.isNaN else {
            guard case let .convertToString(positiveInfinity: posInfString,
                                            negativeInfinity: negInfString,
                                            nan: nanString) = self.options.nonConformingFloatEncodingStrategy else {
                throw EncodingError._invalidFloatingPointValue(double, at: codingPath)
            }

            if double == Double.infinity {
                return NSString(string: posInfString)
            } else if double == -Double.infinity {
                return NSString(string: negInfString)
            } else {
                return NSString(string: nanString)
            }
        }

        return NSNumber(value: double)
    }

    fileprivate func box(_ date: Date) throws -> NSObject {
        switch self.options.dateEncodingStrategy {
        case .deferredToDate:
            // Must be called with a surrounding with(pushedKey:) call.
            try date.encode(to: self)
            return self.storage.popContainer()

        case .secondsSince1970:
            return NSNumber(value: date.timeIntervalSince1970)

        case .millisecondsSince1970:
            return NSNumber(value: 1000.0 * date.timeIntervalSince1970)

        case .iso8601:
            if #available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
                return NSString(string: _iso8601Formatter.string(from: date))
            } else {
                fatalError("ISO8601DateFormatter is unavailable on this platform.")
            }

        case .formatted(let formatter):
            return NSString(string: formatter.string(from: date))

        case .custom(let closure):
            let depth = self.storage.count
            try closure(date, self)

            guard self.storage.count > depth else {
                // The closure didn't encode anything. Return the default keyed container.
                return NSDictionary()
            }

            // We can pop because the closure encoded something.
            return self.storage.popContainer()
        }
    }

    fileprivate func box(_ data: Data) throws -> NSObject {
        switch self.options.dataEncodingStrategy {
        case .base64Encode:
            return NSString(string: data.base64EncodedString())

        case .custom(let closure):
            let depth = self.storage.count
            try closure(data, self)

            guard self.storage.count > depth else {
                // The closure didn't encode anything. Return the default keyed container.
                return NSDictionary()
            }

            // We can pop because the closure encoded something.
            return self.storage.popContainer()
        }
    }

    fileprivate func box<T : Encodable>(_ value: T) throws -> NSObject {
        if T.self == Date.self {
            // Respect Date encoding strategy
            return try self.box((value as! Date))
        } else if T.self == Data.self {
            // Respect Data encoding strategy
            return try self.box((value as! Data))
        } else if T.self == URL.self {
            // Encode URLs as single strings.
            return self.box((value as! URL).absoluteString)
        }

        // The value should request a container from the _JSONEncoder.
        let topContainer = self.storage.containers.last
        try value.encode(to: self)

        // The top container should be a new container.
        guard self.storage.containers.last! !== topContainer else {
            // If the value didn't request a container at all, encode the default container instead.
            return NSDictionary()
        }

        return self.storage.popContainer()
    }
}

// MARK: - _JSONReferencingEncoder

/// _JSONReferencingEncoder is a special subclass of _JSONEncoder which has its own storage, but references the contents of a different encoder.
/// It's used in superEncoder(), which returns a new encoder for encoding a superclass -- the lifetime of the encoder should not escape the scope it's created in, but it doesn't necessarily know when it's done being used (to write to the original container).
fileprivate class _JSONReferencingEncoder : _JSONEncoder {
    // MARK: Reference types.

    /// The type of container we're referencing.
    enum Reference {
        /// Referencing a specific index in an array container.
        case array(NSMutableArray, Int)

        /// Referencing a specific key in a dictionary container.
        case dictionary(NSMutableDictionary, String)
    }

    // MARK: - Properties

    /// The encoder we're referencing.
    let encoder: _JSONEncoder

    /// The container reference itself.
    let reference: Reference

    // MARK: - Initialization

    /// Initializes `self` by referencing the given array container in the given encoder.
    init(referencing encoder: _JSONEncoder, at index: Int, wrapping array: NSMutableArray) {
        self.encoder = encoder
        self.reference = .array(array, index)
        super.init(options: encoder.options, codingPath: encoder.codingPath)

        self.codingPath.append(nil)
    }

    /// Initializes `self` by referencing the given dictionary container in the given encoder.
    init(referencing encoder: _JSONEncoder, at key: CodingKey, wrapping dictionary: NSMutableDictionary) {
        self.encoder = encoder
        self.reference = .dictionary(dictionary, key.stringValue)
        super.init(options: encoder.options, codingPath: encoder.codingPath)

        self.codingPath.append(key)
    }

    // MARK: - Coding Path Operations

    override var canEncodeNewElement: Bool {
        // With a regular encoder, the storage and coding path grow together.
        // A referencing encoder, however, inherits its parents coding path, as well as the key it was created for.
        // We have to take this into account.
        return self.storage.count == self.codingPath.count - self.encoder.codingPath.count - 1
    }

    // MARK: - Deinitialization

    // Finalizes `self` by writing the contents of our storage to the referenced encoder's storage.
    deinit {
        let value: Any
        switch self.storage.count {
        case 0: value = NSDictionary()
        case 1: value = self.storage.popContainer()
        default: fatalError("Referencing encoder deallocated with multiple containers on stack.")
        }

        switch self.reference {
        case .array(let array, let index):
            array.insert(value, at: index)

        case .dictionary(let dictionary, let key):
            dictionary[NSString(string: key)] = value
        }
    }
}

//===----------------------------------------------------------------------===//
// JSON Decoder
//===----------------------------------------------------------------------===//

/// `JSONDecoder` facilitates the decoding of JSON into semantic `Decodable` types.
open class JSONDecoder {
    // MARK: Options

    /// The strategy to use for decoding `Date` values.
    public enum DateDecodingStrategy {
        /// Defer to `Date` for decoding. This is the default strategy.
        case deferredToDate

        /// Decode the `Date` as a UNIX timestamp from a JSON number.
        case secondsSince1970

        /// Decode the `Date` as UNIX millisecond timestamp from a JSON number.
        case millisecondsSince1970

        /// Decode the `Date` as an ISO-8601-formatted string (in RFC 3339 format).
        @available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
        case iso8601

        /// Decode the `Date` as a string parsed by the given formatter.
        case formatted(DateFormatter)

        /// Decode the `Date` as a custom value decoded by the given closure.
        case custom((_ decoder: Decoder) throws -> Date)
    }

    /// The strategy to use for decoding `Data` values.
    public enum DataDecodingStrategy {
        /// Decode the `Data` from a Base64-encoded string. This is the default strategy.
        case base64Decode

        /// Decode the `Data` as a custom value decoded by the given closure.
        case custom((_ decoder: Decoder) throws -> Data)
    }

    /// The strategy to use for non-JSON-conforming floating-point values (IEEE 754 infinity and NaN).
    public enum NonConformingFloatDecodingStrategy {
        /// Throw upon encountering non-conforming values. This is the default strategy.
        case `throw`

        /// Decode the values from the given representation strings.
        case convertFromString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// The strategy to use in decoding dates. Defaults to `.deferredToDate`.
    open var dateDecodingStrategy: DateDecodingStrategy = .deferredToDate

    /// The strategy to use in decoding binary data. Defaults to `.base64Decode`.
    open var dataDecodingStrategy: DataDecodingStrategy = .base64Decode

    /// The strategy to use in decoding non-conforming numbers. Defaults to `.throw`.
    open var nonConformingFloatDecodingStrategy: NonConformingFloatDecodingStrategy = .throw

    /// Contextual user-provided information for use during decoding.
    open var userInfo: [CodingUserInfoKey : Any] = [:]

    /// Options set on the top-level encoder to pass down the decoding hierarchy.
    fileprivate struct _Options {
        let dateDecodingStrategy: DateDecodingStrategy
        let dataDecodingStrategy: DataDecodingStrategy
        let nonConformingFloatDecodingStrategy: NonConformingFloatDecodingStrategy
        let userInfo: [CodingUserInfoKey : Any]
    }

    /// The options set on the top-level decoder.
    fileprivate var options: _Options {
        return _Options(dateDecodingStrategy: dateDecodingStrategy,
                        dataDecodingStrategy: dataDecodingStrategy,
                        nonConformingFloatDecodingStrategy: nonConformingFloatDecodingStrategy,
                        userInfo: userInfo)
    }

    // MARK: - Constructing a JSON Decoder

    /// Initializes `self` with default strategies.
    public init() {}

    // MARK: - Decoding Values

    /// Decodes a top-level value of the given type from the given JSON representation.
    ///
    /// - parameter type: The type of the value to decode.
    /// - parameter data: The data to decode from.
    /// - returns: A value of the requested type.
    /// - throws: `DecodingError.dataCorrupted` if values requested from the payload are corrupted, or if the given data is not valid JSON.
    /// - throws: An error if any value throws an error during decoding.
    open func decode<T : Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let topLevel = try JSONSerialization.jsonObject(with: data)
        let decoder = _JSONDecoder(referencing: topLevel, options: self.options)
        return try T(from: decoder)
    }
}

// MARK: - _JSONDecoder

fileprivate class _JSONDecoder : Decoder {
    // MARK: Properties

    /// The decoder's storage.
    var storage: _JSONDecodingStorage

    /// Options set on the top-level decoder.
    let options: JSONDecoder._Options

    /// The path to the current point in encoding.
    var codingPath: [CodingKey?]

    /// Contextual user-provided information for use during encoding.
    var userInfo: [CodingUserInfoKey : Any] {
        return self.options.userInfo
    }

    // MARK: - Initialization

    /// Initializes `self` with the given top-level container and options.
    init(referencing container: Any, at codingPath: [CodingKey?] = [], options: JSONDecoder._Options) {
        self.storage = _JSONDecodingStorage()
        self.storage.push(container: container)
        self.codingPath = codingPath
        self.options = options
    }

    // MARK: - Coding Path Operations

    /// Performs the given closure with the given key pushed onto the end of the current coding path.
    ///
    /// - parameter key: The key to push. May be nil for unkeyed containers.
    /// - parameter work: The work to perform with the key in the path.
    func with<T>(pushedKey key: CodingKey?, _ work: () throws -> T) rethrows -> T {
        self.codingPath.append(key)
        let ret: T = try work()
        self.codingPath.removeLast()
        return ret
    }

    // MARK: - Decoder Methods

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard !(self.storage.topContainer is NSNull) else {
            throw DecodingError.valueNotFound(KeyedDecodingContainer<Key>.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Cannot get keyed decoding container -- found null value instead."))
        }

        guard let topContainer = self.storage.topContainer as? [String : Any] else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: [String : Any].self, reality: self.storage.topContainer)
        }

        let container = _JSONKeyedDecodingContainer<Key>(referencing: self, wrapping: topContainer)
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard !(self.storage.topContainer is NSNull) else {
            throw DecodingError.valueNotFound(UnkeyedDecodingContainer.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Cannot get unkeyed decoding container -- found null value instead."))
        }

        guard let topContainer = self.storage.topContainer as? [Any] else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: [Any].self, reality: self.storage.topContainer)
        }

        return _JSONUnkeyedDecodingContainer(referencing: self, wrapping: topContainer)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return self
    }
}

// MARK: - Decoding Storage

fileprivate struct _JSONDecodingStorage {
    // MARK: Properties

    /// The container stack.
    /// Elements may be any one of the JSON types (NSNull, NSNumber, String, Array, [String : Any]).
    private(set) var containers: [Any] = []

    // MARK: - Initialization

    /// Initializes `self` with no containers.
    init() {}

    // MARK: - Modifying the Stack

    var count: Int {
        return self.containers.count
    }

    var topContainer: Any {
        precondition(self.containers.count > 0, "Empty container stack.")
        return self.containers.last!
    }

    mutating func push(container: Any) {
        self.containers.append(container)
    }

    mutating func popContainer() {
        precondition(self.containers.count > 0, "Empty container stack.")
        self.containers.removeLast()
    }
}

// MARK: Decoding Containers

fileprivate struct _JSONKeyedDecodingContainer<K : CodingKey> : KeyedDecodingContainerProtocol {
    typealias Key = K

    // MARK: Properties

    /// A reference to the decoder we're reading from.
    let decoder: _JSONDecoder

    /// A reference to the container we're reading from.
    let container: [String : Any]

    /// The path of coding keys taken to get to this point in decoding.
    var codingPath: [CodingKey?]

    // MARK: - Initialization

    /// Initializes `self` by referencing the given decoder and container.
    init(referencing decoder: _JSONDecoder, wrapping container: [String : Any]) {
        self.decoder = decoder
        self.container = container
        self.codingPath = decoder.codingPath
    }

    // MARK: - KeyedDecodingContainerProtocol Methods

    var allKeys: [Key] {
        return self.container.keys.flatMap { Key(stringValue: $0) }
    }

    func contains(_ key: Key) -> Bool {
        return self.container[key.stringValue] != nil
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: Bool.self)
        }
    }

    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: Int.self)
        }
    }

    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: Int8.self)
        }
    }

    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: Int16.self)
        }
    }

    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: Int32.self)
        }
    }

    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: Int64.self)
        }
    }

    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: UInt.self)
        }
    }

    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: UInt8.self)
        }
    }

    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: UInt16.self)
        }
    }

    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: UInt32.self)
        }
    }

    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: UInt64.self)
        }
    }

    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: Float.self)
        }
    }

    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: Double.self)
        }
    }

    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: String.self)
        }
    }

    func decodeIfPresent(_ type: Data.Type, forKey key: Key) throws -> Data? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: Data.self)
        }
    }

    func decodeIfPresent<T : Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        return try self.decoder.with(pushedKey: key) {
            return try self.decoder.unbox(self.container[key.stringValue], as: T.self)
        }
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        return try self.decoder.with(pushedKey: key) {
            guard let value = self.container[key.stringValue] else {
                throw DecodingError.keyNotFound(key,
                                                DecodingError.Context(codingPath: self.codingPath,
                                                                      debugDescription: "Cannot get \(KeyedDecodingContainer<NestedKey>.self) -- no value found for key \"\(key.stringValue)\""))
            }

            guard let dictionary = value as? [String : Any] else {
                throw DecodingError._typeMismatch(at: self.codingPath, expectation: [String : Any].self, reality: value)
            }

            let container = _JSONKeyedDecodingContainer<NestedKey>(referencing: self.decoder, wrapping: dictionary)
            return KeyedDecodingContainer(container)
        }
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        return try self.decoder.with(pushedKey: key) {
            guard let value = self.container[key.stringValue] else {
                throw DecodingError.keyNotFound(key,
                                                DecodingError.Context(codingPath: self.codingPath,
                                                                      debugDescription: "Cannot get UnkeyedDecodingContainer -- no value found for key \"\(key.stringValue)\""))
            }

            guard let array = value as? [Any] else {
                throw DecodingError._typeMismatch(at: self.codingPath, expectation: [Any].self, reality: value)
            }

            return _JSONUnkeyedDecodingContainer(referencing: self.decoder, wrapping: array)
        }
    }

    func _superDecoder(forKey key: CodingKey) throws -> Decoder {
        return try self.decoder.with(pushedKey: key) {
            guard let value = self.container[key.stringValue] else {
                throw DecodingError.keyNotFound(key,
                                                DecodingError.Context(codingPath: self.codingPath,
                                                                      debugDescription: "Cannot get superDecoder() -- no value found for key \"\(key.stringValue)\""))
            }

            return _JSONDecoder(referencing: value, at: self.decoder.codingPath, options: self.decoder.options)
        }
    }

    func superDecoder() throws -> Decoder {
        return try _superDecoder(forKey: _JSONSuperKey.super)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        return try _superDecoder(forKey: key)
    }
}

fileprivate struct _JSONUnkeyedDecodingContainer : UnkeyedDecodingContainer {
    // MARK: Properties

    /// A reference to the decoder we're reading from.
    let decoder: _JSONDecoder

    /// A reference to the container we're reading from.
    let container: [Any]

    /// The path of coding keys taken to get to this point in decoding.
    var codingPath: [CodingKey?]

    /// The index of the element we're about to decode.
    var currentIndex: Int

    // MARK: - Initialization

    /// Initializes `self` by referencing the given decoder and container.
    init(referencing decoder: _JSONDecoder, wrapping container: [Any]) {
        self.decoder = decoder
        self.container = container
        self.codingPath = decoder.codingPath
        self.currentIndex = 0
    }

    // MARK: - UnkeyedDecodingContainer Methods

    var count: Int? {
        return self.container.count
    }

    var isAtEnd: Bool {
        return self.currentIndex >= self.count!
    }

    mutating func decodeIfPresent(_ type: Bool.Type) throws -> Bool? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Bool.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: Int.Type) throws -> Int? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Int.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: Int8.Type) throws -> Int8? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Int8.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: Int16.Type) throws -> Int16? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Int16.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: Int32.Type) throws -> Int32? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Int32.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: Int64.Type) throws -> Int64? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Int64.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: UInt.Type) throws -> UInt? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: UInt.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: UInt8.Type) throws -> UInt8? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: UInt8.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: UInt16.Type) throws -> UInt16? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: UInt16.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: UInt32.Type) throws -> UInt32? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: UInt32.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: UInt64.Type) throws -> UInt64? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: UInt64.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: Float.Type) throws -> Float? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Float.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: Double.Type) throws -> Double? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Double.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: String.Type) throws -> String? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: String.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent(_ type: Data.Type) throws -> Data? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Data.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func decodeIfPresent<T : Decodable>(_ type: T.Type) throws -> T? {
        guard !self.isAtEnd else { return nil }

        return try self.decoder.with(pushedKey: nil) {
            let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: T.self)
            self.currentIndex += 1
            return decoded
        }
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        return try self.decoder.with(pushedKey: nil) {
            guard !self.isAtEnd else {
                throw DecodingError.valueNotFound(KeyedDecodingContainer<NestedKey>.self,
                                                  DecodingError.Context(codingPath: self.codingPath,
                                                                        debugDescription: "Cannot get nested keyed container -- unkeyed container is at end."))
            }

            let value = self.container[self.currentIndex]
            guard !(value is NSNull) else {
                throw DecodingError.valueNotFound(KeyedDecodingContainer<NestedKey>.self,
                                                  DecodingError.Context(codingPath: self.codingPath,
                                                                        debugDescription: "Cannot get keyed decoding container -- found null value instead."))
            }

            guard let dictionary = value as? [String : Any] else {
                throw DecodingError._typeMismatch(at: self.codingPath, expectation: [String : Any].self, reality: value)
            }

            self.currentIndex += 1
            let container = _JSONKeyedDecodingContainer<NestedKey>(referencing: self.decoder, wrapping: dictionary)
            return KeyedDecodingContainer(container)
        }
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        return try self.decoder.with(pushedKey: nil) {
            guard !self.isAtEnd else {
                throw DecodingError.valueNotFound(UnkeyedDecodingContainer.self,
                                                  DecodingError.Context(codingPath: self.codingPath,
                                                                        debugDescription: "Cannot get nested keyed container -- unkeyed container is at end."))
            }

            let value = self.container[self.currentIndex]
            guard !(value is NSNull) else {
                throw DecodingError.valueNotFound(UnkeyedDecodingContainer.self,
                                                  DecodingError.Context(codingPath: self.codingPath,
                                                                        debugDescription: "Cannot get keyed decoding container -- found null value instead."))
            }

            guard let array = value as? [Any] else {
                throw DecodingError._typeMismatch(at: self.codingPath, expectation: [Any].self, reality: value)
            }

            self.currentIndex += 1
            return _JSONUnkeyedDecodingContainer(referencing: self.decoder, wrapping: array)
        }
    }

    mutating func superDecoder() throws -> Decoder {
        return try self.decoder.with(pushedKey: nil) {
            guard !self.isAtEnd else {
                throw DecodingError.valueNotFound(Decoder.self,
                                                  DecodingError.Context(codingPath: self.codingPath,
                                                                        debugDescription: "Cannot get superDecoder() -- unkeyed container is at end."))
            }

            let value = self.container[self.currentIndex]
            guard !(value is NSNull) else {
                throw DecodingError.valueNotFound(Decoder.self,
                                                  DecodingError.Context(codingPath: self.codingPath,
                                                                        debugDescription: "Cannot get superDecoder() -- found null value instead."))
            }

            self.currentIndex += 1
            return _JSONDecoder(referencing: value, at: self.decoder.codingPath, options: self.decoder.options)
        }
    }
}

extension _JSONDecoder : SingleValueDecodingContainer {
    // MARK: SingleValueDecodingContainer Methods

    func decodeNil() -> Bool {
        return self.storage.topContainer is NSNull
    }

    // These all unwrap the result, since we couldn't have gotten a single value container if the topContainer was null.
    func decode(_ type: Bool.Type) throws -> Bool {
        guard let value = try self.unbox(self.storage.topContainer, as: Bool.self) else {
            throw DecodingError.valueNotFound(Bool.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected Bool but found null value instead."))
        }

        return value
    }

    func decode(_ type: Int.Type) throws -> Int {
        guard let value = try self.unbox(self.storage.topContainer, as: Int.self) else {
            throw DecodingError.valueNotFound(Int.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected Int but found null value instead."))
        }

        return value
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        guard let value = try self.unbox(self.storage.topContainer, as: Int8.self) else {
            throw DecodingError.valueNotFound(Int8.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected Int8 but found null value instead."))
        }

        return value
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        guard let value = try self.unbox(self.storage.topContainer, as: Int16.self) else {
            throw DecodingError.valueNotFound(Int16.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected Int16 but found null value instead."))
        }

        return value
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        guard let value = try self.unbox(self.storage.topContainer, as: Int32.self) else {
            throw DecodingError.valueNotFound(Int32.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected Int32 but found null value instead."))
        }

        return value
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        guard let value = try self.unbox(self.storage.topContainer, as: Int64.self) else {
            throw DecodingError.valueNotFound(Int64.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected Int64 but found null value instead."))
        }

        return value
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        guard let value = try self.unbox(self.storage.topContainer, as: UInt.self) else {
            throw DecodingError.valueNotFound(UInt.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected UInt but found null value instead."))
        }

        return value
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        guard let value = try self.unbox(self.storage.topContainer, as: UInt8.self) else {
            throw DecodingError.valueNotFound(UInt8.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected UInt8 but found null value instead."))
        }

        return value
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        guard let value = try self.unbox(self.storage.topContainer, as: UInt16.self) else {
            throw DecodingError.valueNotFound(UInt16.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected UInt16 but found null value instead."))
        }

        return value
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        guard let value = try self.unbox(self.storage.topContainer, as: UInt32.self) else {
            throw DecodingError.valueNotFound(UInt32.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected UInt32 but found null value instead."))
        }

        return value
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        guard let value = try self.unbox(self.storage.topContainer, as: UInt64.self) else {
            throw DecodingError.valueNotFound(UInt64.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected UInt64 but found null value instead."))
        }

        return value
    }

    func decode(_ type: Float.Type) throws -> Float {
        guard let value = try self.unbox(self.storage.topContainer, as: Float.self) else {
            throw DecodingError.valueNotFound(Float.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected Float but found null value instead."))
        }

        return value
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard let value = try self.unbox(self.storage.topContainer, as: Double.self) else {
            throw DecodingError.valueNotFound(Double.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected Double but found null value instead."))
        }

        return value
    }

    func decode(_ type: String.Type) throws -> String {
        guard let value = try self.unbox(self.storage.topContainer, as: String.self) else {
            throw DecodingError.valueNotFound(String.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected String but found null value instead."))
        }

        return value
    }

    func decode<T : Decodable>(_ type: T.Type) throws -> T {
        guard let value = try self.unbox(self.storage.topContainer, as: T.self) else {
            throw DecodingError.valueNotFound(T.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Expected \(T.self) but found null value instead."))
        }

        return value
    }
}

// MARK: - Concrete Value Representations

extension _JSONDecoder {
    /// Returns the given value unboxed from a container.
    fileprivate func unbox(_ value: Any?, as type: Bool.Type) throws -> Bool? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        if let number = value as? NSNumber {
            // TODO: Add a flag to coerce non-boolean numbers into Bools?
            if number === kCFBooleanTrue as NSNumber {
                return true
            } else if number === kCFBooleanFalse as NSNumber {
                return false
            }

        /* FIXME: If swift-corelibs-foundation doesn't change to use NSNumber, this code path will need to be included and tested:
        } else if let bool = value as? Bool {
            return bool
        */

        }

        throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
    }

    fileprivate func unbox(_ value: Any?, as type: Int.Type) throws -> Int? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let number = value as? NSNumber else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        let int = number.intValue
        guard NSNumber(value: int) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }

        return int
    }

    fileprivate func unbox(_ value: Any?, as type: Int8.Type) throws -> Int8? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let number = value as? NSNumber else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        let int8 = number.int8Value
        guard NSNumber(value: int8) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }

        return int8
    }

    fileprivate func unbox(_ value: Any?, as type: Int16.Type) throws -> Int16? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let number = value as? NSNumber else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        let int16 = number.int16Value
        guard NSNumber(value: int16) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }

        return int16
    }

    fileprivate func unbox(_ value: Any?, as type: Int32.Type) throws -> Int32? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let number = value as? NSNumber else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        let int32 = number.int32Value
        guard NSNumber(value: int32) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }

        return int32
    }

    fileprivate func unbox(_ value: Any?, as type: Int64.Type) throws -> Int64? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let number = value as? NSNumber else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        let int64 = number.int64Value
        guard NSNumber(value: int64) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }

        return int64
    }

    fileprivate func unbox(_ value: Any?, as type: UInt.Type) throws -> UInt? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let number = value as? NSNumber else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        let uint = number.uintValue
        guard NSNumber(value: uint) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }

        return uint
    }

    fileprivate func unbox(_ value: Any?, as type: UInt8.Type) throws -> UInt8? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let number = value as? NSNumber else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        let uint8 = number.uint8Value
        guard NSNumber(value: uint8) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }

        return uint8
    }

    fileprivate func unbox(_ value: Any?, as type: UInt16.Type) throws -> UInt16? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let number = value as? NSNumber else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        let uint16 = number.uint16Value
        guard NSNumber(value: uint16) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }

        return uint16
    }

    fileprivate func unbox(_ value: Any?, as type: UInt32.Type) throws -> UInt32? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let number = value as? NSNumber else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        let uint32 = number.uint32Value
        guard NSNumber(value: uint32) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }

        return uint32
    }

    fileprivate func unbox(_ value: Any?, as type: UInt64.Type) throws -> UInt64? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let number = value as? NSNumber else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        let uint64 = number.uint64Value
        guard NSNumber(value: uint64) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }

        return uint64
    }

    fileprivate func unbox(_ value: Any?, as type: Float.Type) throws -> Float? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        if let number = value as? NSNumber {
            // We are willing to return a Float by losing precision:
            // * If the original value was integral,
            //   * and the integral value was > Float.greatestFiniteMagnitude, we will fail
            //   * and the integral value was <= Float.greatestFiniteMagnitude, we are willing to lose precision past 2^24
            // * If it was a Float, you will get back the precise value
            // * If it was a Double or Decimal, you will get back the nearest approximation if it will fit
            let double = number.doubleValue
            guard abs(double) <= Double(Float.greatestFiniteMagnitude) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number \(number) does not fit in \(type)."))
            }

            return Float(double)

        /* FIXME: If swift-corelibs-foundation doesn't change to use NSNumber, this code path will need to be included and tested:
        } else if let double = value as? Double {
            if abs(double) <= Double(Float.max) {
                return Float(double)
            }

            overflow = true
        } else if let int = value as? Int {
            if let float = Float(exactly: int) {
                return float
            }

            overflow = true
        */

        } else if let string = value as? String,
            case .convertFromString(let posInfString, let negInfString, let nanString) = self.options.nonConformingFloatDecodingStrategy {
            if string == posInfString {
                return Float.infinity
            } else if string == negInfString {
                return -Float.infinity
            } else if string == nanString {
                return Float.nan
            }
        }

        throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
    }

    func unbox(_ value: Any?, as type: Double.Type) throws -> Double? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        if let number = value as? NSNumber {
            // We are always willing to return the number as a Double:
            // * If the original value was integral, it is guaranteed to fit in a Double; we are willing to lose precision past 2^53 if you encoded a UInt64 but requested a Double
            // * If it was a Float or Double, you will get back the precise value
            // * If it was Decimal, you will get back the nearest approximation
            return number.doubleValue

        /* FIXME: If swift-corelibs-foundation doesn't change to use NSNumber, this code path will need to be included and tested:
        } else if let double = value as? Double {
            return double
        } else if let int = value as? Int {
            if let double = Double(exactly: int) {
                return double
            }

            overflow = true
        */

        } else if let string = value as? String,
            case .convertFromString(let posInfString, let negInfString, let nanString) = self.options.nonConformingFloatDecodingStrategy {
            if string == posInfString {
                return Double.infinity
            } else if string == negInfString {
                return -Double.infinity
            } else if string == nanString {
                return Double.nan
            }
        }

        throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
    }

    func unbox(_ value: Any?, as type: String.Type) throws -> String? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        guard let string = value as? String else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }

        return string
    }

    func unbox(_ value: Any?, as type: Date.Type) throws -> Date? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        switch self.options.dateDecodingStrategy {
        case .deferredToDate:
            self.storage.push(container: value)
            let date = try Date(from: self)
            self.storage.popContainer()
            return date

        case .secondsSince1970:
            let double = try self.unbox(value, as: Double.self)!
            return Date(timeIntervalSince1970: double)

        case .millisecondsSince1970:
            let double = try self.unbox(value, as: Double.self)!
            return Date(timeIntervalSince1970: double / 1000.0)

        case .iso8601:
            if #available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
                let string = try self.unbox(value, as: String.self)!
                guard let date = _iso8601Formatter.date(from: string) else {
                    throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Expected date string to be ISO8601-formatted."))
                }

                return date
            } else {
                fatalError("ISO8601DateFormatter is unavailable on this platform.")
            }

        case .formatted(let formatter):
            let string = try self.unbox(value, as: String.self)!
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Date string does not match format expected by formatter."))
            }

            return date

        case .custom(let closure):
            self.storage.push(container: value)
            let date = try closure(self)
            self.storage.popContainer()
            return date
        }
    }

    func unbox(_ value: Any?, as type: Data.Type) throws -> Data? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        switch self.options.dataDecodingStrategy {
        case .base64Decode:
            guard let string = value as? String else {
                throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
            }

            guard let data = Data(base64Encoded: string) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Encountered Data is not valid Base64."))
            }

            return data

        case .custom(let closure):
            self.storage.push(container: value)
            let data = try closure(self)
            self.storage.popContainer()
            return data
        }
    }

    func unbox<T : Decodable>(_ value: Any?, as type: T.Type) throws -> T? {
        guard let value = value else { return nil }
        guard !(value is NSNull) else { return nil }

        let decoded: T
        if T.self == Date.self {
            decoded = (try self.unbox(value, as: Date.self) as! T)
        } else if T.self == Data.self {
            decoded = (try self.unbox(value, as: Data.self) as! T)
        } else if T.self == URL.self {
            guard let urlString = try self.unbox(value, as: String.self) else {
                return nil
            }

            guard let url = URL(string: urlString) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath,
                                                                        debugDescription: "Invalid URL string."))
            }

            decoded = (url as! T)
        } else {
            self.storage.push(container: value)
            decoded = try T(from: self)
            self.storage.popContainer()
        }

        return decoded
    }
}

//===----------------------------------------------------------------------===//
// Shared Super Key
//===----------------------------------------------------------------------===//

fileprivate enum _JSONSuperKey : String, CodingKey {
    case `super`
}

//===----------------------------------------------------------------------===//
// Shared ISO8601 Date Formatter
//===----------------------------------------------------------------------===//

// NOTE: This value is implicitly lazy and _must_ be lazy. We're compiled against the latest SDK (w/ ISO8601DateFormatter), but linked against whichever Foundation the user has. ISO8601DateFormatter might not exist, so we better not hit this code path on an older OS.
@available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
fileprivate var _iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = .withInternetDateTime
    return formatter
}()

//===----------------------------------------------------------------------===//
// Error Utilities
//===----------------------------------------------------------------------===//

fileprivate extension EncodingError {
    /// Returns a `.invalidValue` error describing the given invalid floating-point value.
    ///
    ///
    /// - parameter value: The value that was invalid to encode.
    /// - parameter path: The path of `CodingKey`s taken to encode this value.
    /// - returns: An `EncodingError` with the appropriate path and debug description.
    fileprivate static func _invalidFloatingPointValue<T : FloatingPoint>(_ value: T, at codingPath: [CodingKey?]) -> EncodingError {
        let valueDescription: String
        if value == T.infinity {
            valueDescription = "\(T.self).infinity"
        } else if value == -T.infinity {
            valueDescription = "-\(T.self).infinity"
        } else {
            valueDescription = "\(T.self).nan"
        }

        let debugDescription = "Unable to encode \(valueDescription) directly in JSON. Use JSONEncoder.NonConformingFloatEncodingStrategy.convertToString to specify how the value should be encoded."
        return .invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: debugDescription))
    }
}
