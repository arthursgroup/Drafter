//
//  ParserRunner.swift
//  drafterPackageDescription
//
//  Created by LZephyr on 2018/1/27.
//

import Foundation

fileprivate let maxConcurrent: Int = 4 // 多线程解析最大并发数

class ParserRunner {
    
    static let runner = ParserRunner()

    func parse(files: [String]) -> [ClassNode] {
        let ocFiles = files.filter { $0.hasSuffix(".h") || $0.hasSuffix(".m") }
        let swiftFiles = files.filter { $0.hasSuffix(".swift") }
        
        interfaces = []
        implementations = []
        classList = []
        
        // 1. 解析OC文件
        for file in ocFiles {
            print("Parsing: \(file.components(separatedBy: "/").last ?? file)")
            semaphore.wait()
            DispatchQueue.global().async {
                let tokens = SourceLexer(file: file).allTokens
                let interface = InterfaceParser().parser.run(tokens) ?? []
                let imp = ImplementationParser().parser.run(tokens) ?? []
                
                self.interfaces.append(contentsOf: interface)
                self.implementations.append(contentsOf: imp)
                self.semaphore.signal()
            }
        }
        
        // 2. 解析Swift文件
        for file in swiftFiles {
            print("Parsing: \(file.components(separatedBy: "/").last ?? file)")
            semaphore.wait()
            DispatchQueue.global().async {
                let tokens = SourceLexer(file: file).allTokens
                let (_, classes) = SwiftParser().parser.run(tokens) ?? ([],[])
                
                self.classList.append(contentsOf: classes)
                self.semaphore.signal()
            }
        }
        
        waitUntilFinished()

        // 3. 结果整合
        let impDic = implementations.merged()
        for interface in interfaces {
            let cls = ClassNode(interface: interface, implementation: impDic[interface.className])
            classList.append(cls)
        }
                
        return classList.distinct
    }

    fileprivate let semaphore = DispatchSemaphore(value: maxConcurrent)
    fileprivate var interfaces: [InterfaceNode] = []
    fileprivate var implementations: [ImplementationNode] = []
    fileprivate var classList: [ClassNode] = []
}

// MARK: - 0.2.0以前的旧接口

extension ParserRunner {
    /// 解析代码中的方法调用
    ///
    /// - Parameter files: 输入的文件路径
    /// - Returns: 字典，key为文件，value为方法数组
    func parseMethods(files: [String]) -> [String: [MethodNode]] {
        var results = [String: [MethodNode]]()
        
        func runParse(_ file: String) -> [MethodNode] {
            print("Parsing \(file)...")
            let tokens = SourceLexer(file: file).allTokens
            var nodes = [MethodNode]()
            
            if file.isSwift {
                let result = SwiftMethodParser().parser.run(tokens) ?? []
                nodes.append(contentsOf: result)
            } else {
                let result = ObjcMethodParser().parser.run(tokens) ?? []
                nodes.append(contentsOf: result)
            }
            return nodes
        }
        
        // 1. 解析方法调用
        let sources = files.filter({ !$0.hasSuffix(".h") })
        for file in sources {
            semaphore.wait()
            DispatchQueue.global().async {
                results[file] = runParse(file)
                self.semaphore.signal()
            }
        }
        
        waitUntilFinished()
        
        return results
    }
    
    /// 解析代码中的类型
    ///
    /// - Parameter files: 文件
    /// - Returns: 返回一个元组，分别为所有的类型和协议数据
    func parseInerit(files: [String]) -> ([ClassNode], [ProtocolNode]) {
        var classes = [ClassNode]()
        var protocols = [ProtocolNode]()
        let writeQueue = DispatchQueue(label: "WriteClass")
        
        // 解析OC类型
        func parseObjcClass(_ file: String) {
            print("Parsing \(file)...")
            let tokens = SourceLexer(file: file).allTokens
            let result = InterfaceParser().parser.toClassNode.run(tokens) ?? []
            writeQueue.sync {
                classes.merge(result)
            }
        }
        
        // 解析swift类型
        func parseSwiftClass(_ file: String) {
            print("Parsing \(file)...")
            let tokens = SourceLexer(file: file).allTokens
            let (protos, cls) = SwiftParser().parser.run(tokens) ?? ([], [])
            writeQueue.sync {
                protocols.append(contentsOf: protos)
                classes.merge(cls)
            }
        }
        
        // 1. 解析OC文件
        for file in files.filter({ !$0.isSwift }) {
            semaphore.wait()
            DispatchQueue.global().async {
                parseObjcClass(file)
                self.semaphore.signal()
            }
        }
        
        // 2. 解析swift文件
        for file in files.filter({ $0.isSwift }) {
            semaphore.wait()
            DispatchQueue.global().async {
                parseSwiftClass(file)
                self.semaphore.signal()
            }
        }
        
        // 3. 等待所有线程执行结束
        waitUntilFinished()
        
        return (classes, protocols)
    }
}

// MARK: - Private

extension ParserRunner {
    /// 等待直到所有任务完成
    private func waitUntilFinished() {
        for _ in 0..<maxConcurrent {
            semaphore.wait()
        }
        for _ in 0..<maxConcurrent {
            semaphore.signal()
        }
    }
}

fileprivate extension Array where Element == ImplementationNode {
    /// 合并相同类型的Imp节点，保存在字典中返回
    func merged() -> [String: ImplementationNode] {
        var impDic = [String: ImplementationNode]()
        for imp in self {
            if impDic.keys.contains(imp.className) {
                impDic[imp.className]?.methods.append(contentsOf: imp.methods)
            } else {
                impDic[imp.className] = imp
            }
        }
        
        return impDic
    }
}
