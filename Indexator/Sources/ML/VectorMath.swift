// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
import Foundation

enum VectorMath {
    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        var divisor = norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// Dot product of `query` with every row of a row-major matrix stored flat.
    static func scores(query: [Float], matrix: [Float], rows: Int) -> [Float] {
        let dim = query.count
        guard rows > 0, dim > 0, matrix.count >= rows * dim else { return [] }
        var result = [Float](repeating: 0, count: rows)
        // result (rows x 1) = matrix (rows x dim) * query (dim x 1)
        vDSP_mmul(matrix, 1, query, 1, &result, 1, vDSP_Length(rows), 1, vDSP_Length(dim))
        return result
    }
}
