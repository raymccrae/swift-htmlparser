//
//  HTMLSAXParser+libxml2.swift
//  HTMLSAXParser
//
//  Created by Raymond Mccrae on 20/07/2017.
//  Copyright © 2017 Raymond McCrae.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import CHTMLSAXParser

internal extension HTMLSAXParser {

    /// The libxml2 sax handlers. We only need one global instanse as the parsing context will track
    /// instance specific details.
    private static let libxmlSAXHandler: htmlSAXHandler = createSAXHandler()

    /// The internal parse method that contains the integration with libxml2.
    ///
    /// - parameter data: The data containing the HTML content.
    /// - Parameter encoding: The character encoding to interpret the data. If no encoding
    /// is given then the parser will attempt to detect the encoding.
    /// - Parameter handler: The event handler closure that will be called during parsing.
    /// - Throws: `HTMLParser.Error` if a fatal error occured during parsing.
    // swiftlint:disable:next identifier_name
    func _parse(data: Data, encoding: String.Encoding?, handler: EventHandler) throws {
        let dataLength = data.count
        var charEncoding: xmlCharEncoding = XML_CHAR_ENCODING_NONE

        if let encoding = encoding {
            charEncoding = convert(from: encoding)
        } else {
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Void in
                let dataBytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                charEncoding = xmlDetectCharEncoding(dataBytes, Int32(dataLength))
            }
        }

        guard charEncoding != XML_CHAR_ENCODING_ERROR else {
            throw Error.unsupportedCharEncoding
        }

        try withoutActuallyEscaping(handler) { (escapingHandler) -> Void in
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Void in
                let dataBytes = buffer.baseAddress?.assumingMemoryBound(to: Int8.self)
                let handlerContext = HandlerContext(handler: escapingHandler)
                let handlerContextPtr = Unmanaged<HandlerContext>.passUnretained(handlerContext).toOpaque()
                var libxmlHandler = HTMLSAXParser.libxmlSAXHandler
                guard let parserContext = htmlCreatePushParserCtxt(&libxmlHandler,
                                                                   handlerContextPtr,
                                                                   dataBytes,
                                                                   Int32(dataLength),
                                                                   nil,
                                                                   charEncoding) else {
                                                                    throw Error.unknown
                }
                defer {
                    // Free the parser context when we exit the scope.
                    htmlFreeParserCtxt(parserContext)
                    handlerContext.contextPtr = nil
                }

                handlerContext.contextPtr = parserContext
                let options = CInt(self.parseOptions.rawValue)
                htmlCtxtUseOptions(parserContext, options)

                let parseResult = htmlParseDocument(parserContext)
                try self.handleParseResult(parseResult, handlerContext)
            }
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func convert(from swiftEncoding: String.Encoding) -> xmlCharEncoding {
        switch swiftEncoding {
        case .utf8:
            return XML_CHAR_ENCODING_UTF8
        case .utf16LittleEndian:
            return XML_CHAR_ENCODING_UTF16LE
        case .utf16BigEndian:
            return XML_CHAR_ENCODING_UTF16BE
        case .utf16:
            switch UInt32(CFByteOrderGetCurrent()) {
            case CFByteOrderBigEndian.rawValue:
                return XML_CHAR_ENCODING_UTF16BE

            case CFByteOrderLittleEndian.rawValue:
                return XML_CHAR_ENCODING_UTF16LE

            default:
                return XML_CHAR_ENCODING_NONE
            }
        case .utf32LittleEndian:
            return XML_CHAR_ENCODING_UCS4LE
        case .utf32BigEndian:
            return XML_CHAR_ENCODING_UCS4BE
        case .utf32:
            switch UInt32(CFByteOrderGetCurrent()) {
            case CFByteOrderBigEndian.rawValue:
                return XML_CHAR_ENCODING_UCS4BE

            case CFByteOrderLittleEndian.rawValue:
                return XML_CHAR_ENCODING_UCS4LE

            default:
                return XML_CHAR_ENCODING_NONE
            }
        case .isoLatin1:
            return XML_CHAR_ENCODING_8859_1
        case .isoLatin2:
            return XML_CHAR_ENCODING_8859_2
        case .japaneseEUC:
            return XML_CHAR_ENCODING_EUC_JP
        case .iso2022JP:
            return XML_CHAR_ENCODING_2022_JP
        case .shiftJIS:
            return XML_CHAR_ENCODING_SHIFT_JIS
        case .ascii:
            return XML_CHAR_ENCODING_ASCII

        default:
            return XML_CHAR_ENCODING_NONE
        }
    }

    /// Handle the parse result from the underlying libxml2 htmlParseDocument call. Determines if the parse method
    /// should throw a parsingFailure error. This will check the result did not end with a fatal error. Other less
    /// serious error levels will be considered a success.
    ///
    /// One success the method returns, otherwise the method throws an `HTMLParser.Error`
    ///
    /// - Parameter parseResult: The result from the libxml2 htmlParseDocument call.
    /// - Parameter handlerContext: The handler context.
    /// - Throws: `HTMLParser.Error` if the parsing ended with a fatel error.
    private func handleParseResult(_ parseResult: Int32, _ handlerContext: HTMLSAXParser.HandlerContext) throws {
        // htmlParseDocument returns zero for success, therefore if non-zero we need to check the last error.
        if parseResult != 0 {
            guard let error = handlerContext.lastError() else {
                    // If no last error was found then just return.
                    return
            }

            let errorLevel = error.pointee.level
            switch errorLevel {
            case XML_ERR_FATAL: // if fatal then throw a parsingFailure
                let message: String
                if let messageCString = error.pointee.message {
                    message = String(cString: messageCString).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    message = ""
                }

                let location = Location(line: Int(error.pointee.line), column: Int(error.pointee.int2))

                throw Error.parsingFailure(location: location, message: message)
            default: // All other levels of error will be considered success
                break
            }
        }
    }

    /// The Handler Context is an object representing the pasing context that is given as a parameter to the
    /// event handler closure. For the most part it is a wrapper around the libxml2 parser context (htmlParserCtxtPtr).
    private class HandlerContext: HTMLSAXParseContext {

        /// The event handler closure
        let handler: EventHandler

        /// The libxml2 parser context
        var contextPtr: htmlParserCtxtPtr?

        init(handler: @escaping EventHandler) {
            self.handler = handler
        }

        /// Get the current parsing location. If not currently parsing line and column will be zero.
        var location: Location {
            guard let contextPtr = contextPtr else {
                return Location(line: 0, column: 0)
            }
            let lineNumber = Int(xmlSAX2GetLineNumber(contextPtr))
            let columnNumber = Int(xmlSAX2GetColumnNumber(contextPtr))
            let loc = Location(line: lineNumber, column: columnNumber)
            return loc
        }

        /// Get the System ID if available.
        var systemId: String? {
            guard let contextPtr = contextPtr else {
                return nil
            }
            guard let systemId = xmlSAX2GetSystemId(contextPtr) else {
                return nil
            }
            return String(cString: systemId)
        }

        /// Get the Public ID if available.
        var publicId: String? {
            guard let contextPtr = contextPtr else {
                return nil
            }
            guard let publicId = xmlSAX2GetPublicId(contextPtr) else {
                return nil
            }
            return String(cString: publicId)

        }

        /// Aborts the parsing task. The no further calls to the event handler closure will be may
        /// for the currently parsing task.
        ///
        /// This method is intended to be called from the event handler closure only. This method should
        /// only be called from the dispatch queue invoking the event handler.
        func abortParsing() {
            guard let contextPtr = contextPtr else {
                return
            }

            xmlStopParser(contextPtr)
        }

        /// Get the last libxml2 parsing error to occur if available.
        ///
        /// - returns: A pointer to the last parsing error or nil if not available.
        fileprivate func lastError() -> xmlErrorPtr? {
            guard let contextPtr = contextPtr, let errorPtr = xmlCtxtGetLastError(contextPtr) else {
                return nil
            }
            return errorPtr
        }

        fileprivate static func fromUnsafeRawPointer(_ context: UnsafeRawPointer) -> HandlerContext {
            return Unmanaged<HandlerContext>.fromOpaque(context).takeUnretainedValue()
        }
    }

    /// Create a htmlSAXHandler instance for the libxml2 html parser. The created htmlSAXHandler struct
    /// will have the various function pointers set to the relevant Swift closures to process the event
    /// and forward the event to the EventHandler closure within the parsing context.
    ///
    /// - Returns: An instance of htmlSAXHandler with the function pointers set.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func createSAXHandler() -> htmlSAXHandler {
        var handler = htmlSAXHandler()

        handler.startDocument = { (context: UnsafeMutableRawPointer?) in
            guard let context = context else {
                return
            }

            let handlerContext = HandlerContext.fromUnsafeRawPointer(context)
            handlerContext.handler(handlerContext, .startDocument)
        }

        handler.endDocument = { (context: UnsafeMutableRawPointer?) in
            guard let context = context else {
                return
            }

            let handlerContext = HandlerContext.fromUnsafeRawPointer(context)
            handlerContext.handler(handlerContext, .endDocument)
        }

        handler.startElement = { (context: UnsafeMutableRawPointer?,
            name: UnsafePointer<UInt8>?,
            attrs: UnsafeMutablePointer<UnsafePointer<UInt8>?>?) in
            guard let context = context, let name = name else {
                return
            }

            let handlerContext = HandlerContext.fromUnsafeRawPointer(context)
            let elementName = String(cString: name)
            var elementAttributes: [String: String] = [:]

            if let attrs = attrs {
                var attrPtr = attrs.advanced(by: 0)

                while true {
                    let attrName = attrPtr.pointee
                    if let attrName = attrName {
                        let attributeName = String(cString: attrName)
                        attrPtr = attrPtr.advanced(by: 1)

                        if let attrValue = attrPtr.pointee {
                            let attributeValue = String(cString: attrValue)
                            elementAttributes[attributeName] = attributeValue
                        } else {
                            // If the attribute does not have a value then use the attribute name as the value.
                            elementAttributes[attributeName] = attributeName
                        }
                        attrPtr = attrPtr.advanced(by: 1)
                    } else {
                        break
                    }
                }
            }

            handlerContext.handler(handlerContext,
                                   .startElement(name: elementName,
                                                 attributes: elementAttributes))
        }

        handler.endElement = { (context, name) in
            guard let context = context, let name = name else {
                return
            }

            let handlerContext = HandlerContext.fromUnsafeRawPointer(context)
            let elementName = String(cString: name)

            handlerContext.handler(handlerContext, .endElement(name: elementName))
        }

        handler.characters = { (context, characters, length) in
            guard let context = context, let characters = characters else {
                return
            }

            let ptr = UnsafeMutableRawPointer(OpaquePointer(characters))
            let data = Data(bytesNoCopy: ptr,
                            count: Int(length),
                            deallocator: .none)
            guard let text = String(data: data, encoding: .utf8) else {
                return
            }

            let handlerContext = HandlerContext.fromUnsafeRawPointer(context)
            handlerContext.handler(handlerContext, .characters(text: text))

        }

        handler.processingInstruction = { (context, target, data) in
            guard let context = context, let target = target else {
                return
            }

            let targetString = String(cString: target)
            let dataString: String?
            if let data = data {
                dataString = String(cString: data)
            } else {
                dataString = nil
            }

            let handlerContext = HandlerContext.fromUnsafeRawPointer(context)
            handlerContext.handler(handlerContext,
                                   .processingInstruction(target: targetString,
                                                          data: dataString))
        }

        handler.comment = { (context, comment) in
            guard let context = context, let comment = comment else {
                return
            }

            let commentString = String(cString: comment)
            let handlerContext = HandlerContext.fromUnsafeRawPointer(context)
            handlerContext.handler(handlerContext, .comment(text: commentString))
        }

        handler.cdataBlock = { (context, block, length) in
            guard let context = context, let block = block else {
                return
            }

            let dataBlock = Data(bytes: block, count: Int(length))
            let handlerContext = HandlerContext.fromUnsafeRawPointer(context)
            handlerContext.handler(handlerContext, .cdata(block: dataBlock))
        }

        // Set the global error and warning handler functions.
        _ = HTMLSAXParser.globalErrorHandler
        _ = HTMLSAXParser.globalWarningHandler
        withUnsafeMutablePointer(to: &handler) { (handlerPtr) in
            htmlparser_set_global_error_handler(handlerPtr)
            htmlparser_set_global_warning_handler(handlerPtr)
        }

        return handler
    }

    /// The global error handler for all HTML parsing tasks.
    private static let globalErrorHandler: HTMLParserWrappedErrorSAXFunc = {
        // We only want to set this global once ever. Regardless of the number of instances of parsers.
        htmlparser_global_error_sax_func = {context, message in
            guard let context = context else {
                return
            }

            let messageString: String
            if let message = message {
                messageString = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                messageString = ""
            }
            let handlerContext = HandlerContext.fromUnsafeRawPointer(context)
            handlerContext.handler(handlerContext, .error(message: messageString))
        }
        return htmlparser_global_error_sax_func
    }()
    private static let globalWarningHandler: HTMLParserWrappedWarningSAXFunc = {
        // We only want to set this global once ever. Regardless of the number of instances of parsers.
        htmlparser_global_warning_sax_func = { context, message in
            guard let context = context else {
                return
            }

            let messageString: String
            if let message = message {
                messageString = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                messageString = ""
            }
            let handlerContext = HandlerContext.fromUnsafeRawPointer(context)
            handlerContext.handler(handlerContext, .warning(message: messageString))
        }
        return htmlparser_global_warning_sax_func
    }()
}
