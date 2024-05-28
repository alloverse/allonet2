//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-28.
//

import Foundation

func with<T>(_ value: T, using closure: (inout T) -> Void) -> T {
    var copy = value
    closure(&copy)
    return copy
}
