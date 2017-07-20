//
//  HTMLParser+libxml2.swift
//  HTMLParser
//
//  Created by Raymond Mccrae on 20/07/2017.
//  Copyright © 2017 Raymond Mccrae. All rights reserved.
//

import Foundation
import libxml2

internal extension HTMLParser {
    
    func _parse(data: Data, encoding: String.Encoding?, handler: @escaping EventHandler) throws {
        let dataLength = data.count
        var charEncoding: xmlCharEncoding = XML_CHAR_ENCODING_NONE
        
        try data.withUnsafeBytes { (dataBytes: UnsafePointer<UInt8>) -> Void in
            
            if let encoding = encoding {
                charEncoding = convert(from: encoding)
            }
            else {
                charEncoding = xmlDetectCharEncoding(dataBytes, Int32(dataLength))
            }
            
            guard charEncoding != XML_CHAR_ENCODING_NONE && charEncoding != XML_CHAR_ENCODING_ERROR else {
                throw Error.unsupportedCharEncoding
            }
        }
        
        try data.withUnsafeBytes{ (dataBytes: UnsafePointer<Int8>) -> Void in
            let handlerContext = HandlerContext(handler: handler)
            let handlerContextPtr = Unmanaged<HandlerContext>.passUnretained(handlerContext).toOpaque()
            var libxmlHandler = saxHandler()
            guard let parserContext = htmlCreatePushParserCtxt(&libxmlHandler, handlerContextPtr, dataBytes, Int32(dataLength), nil, charEncoding) else {
                throw Error.unknown
            }
            defer {
                // Free the parser context when we exit the scope.
                htmlFreeParserCtxt(parserContext)
                handlerContext.contextPtr = nil
            }
            
            handlerContext.contextPtr = parserContext
            
            htmlCtxtUseOptions(parserContext, Int32(HTML_PARSE_RECOVER.rawValue) | Int32(HTML_PARSE_NONET.rawValue) | Int32(HTML_PARSE_COMPACT.rawValue) | Int32(HTML_PARSE_NOBLANKS.rawValue) | Int32(HTML_PARSE_NOIMPLIED.rawValue))
            
            let _ = htmlParseDocument(parserContext)
        }
    }
    
    func convert(from swiftEncoding: String.Encoding) -> xmlCharEncoding {
        switch swiftEncoding {
        case .utf8:
            return XML_CHAR_ENCODING_UTF8
        case .utf16LittleEndian:
            return XML_CHAR_ENCODING_UTF16LE
        case .utf16BigEndian:
            return XML_CHAR_ENCODING_UTF16BE
        case .isoLatin1:
            return XML_CHAR_ENCODING_8859_1
        case .isoLatin2:
            return XML_CHAR_ENCODING_8859_2
            
        default:
            return XML_CHAR_ENCODING_NONE
        }
    }
    
    private class HandlerContext {
        let handler: EventHandler
        var contextPtr: htmlParserCtxtPtr?
        
        init(handler: @escaping EventHandler) {
            self.handler = handler
        }
        
        func location() -> Location {
            guard let contextPtr = contextPtr else {
                return Location(line: 0, column: 0)
            }
            let lineNumber = Int(xmlSAX2GetLineNumber(contextPtr))
            let columnNumber = Int(xmlSAX2GetColumnNumber(contextPtr))
            let loc = Location(line: lineNumber, column: columnNumber)
            return loc
        }
    }
    
    private func saxHandler() -> htmlSAXHandler {
        var handler = htmlSAXHandler()
        
        handler.startDocument = { (context: UnsafeMutableRawPointer?) in
            guard let context = context else {
                return
            }
            
            let handlerContext: HandlerContext = Unmanaged<HandlerContext>.fromOpaque(context).takeUnretainedValue()
            handlerContext.handler(.startDocument(location: handlerContext.location))
        }
        
        handler.endDocument = { (context: UnsafeMutableRawPointer?) in
            guard let context = context else {
                return
            }
            
            let handlerContext: HandlerContext = Unmanaged<HandlerContext>.fromOpaque(context).takeUnretainedValue()
            handlerContext.handler(.endDocument(location: handlerContext.location))
        }
        
        handler.startElement = { (context: UnsafeMutableRawPointer?,
            name: UnsafePointer<UInt8>?,
            attrs: UnsafeMutablePointer<UnsafePointer<UInt8>?>?) in
            guard let context = context, let name = name else {
                return
            }
            
            let handlerContext: HandlerContext = Unmanaged<HandlerContext>.fromOpaque(context).takeUnretainedValue()
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
                        }
                        else {
                            elementAttributes[attributeName] = ""
                        }
                    }
                    else {
                        break
                    }
                    
                    
                }
            }
            
            handlerContext.handler(.startElement(name: elementName,
                                                 attributes: elementAttributes,
                                                 location: handlerContext.location))
        }
        
        //        handler.endElement = nil
        
        handler.characters = { (context, characters, length) in
            guard let context = context, let characters = characters else {
                return
            }
            
            // There does not seem to be a good String initializer that takes a
            // pointer to bytes and a length parameters. Falling back to NSString.
            guard let characterNSString = NSString(bytes: characters,
                                                   length: Int(length),
                                                   encoding: String.Encoding.utf8.rawValue) else {
                                                    return
            }
            
            let handlerContext: HandlerContext = Unmanaged<HandlerContext>.fromOpaque(context).takeUnretainedValue()
            handlerContext.handler(.characters(text: characterNSString as String,
                                               location: handlerContext.location))
            
        }
        //        handler.ignorableWhitespace = nil
        handler.processingInstruction = nil
        
        return handler
    }
}