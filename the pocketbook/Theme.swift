//
//  Theme.swift
//  the pocketbook
//

import SwiftUI

enum Theme {
    /// Carta del taccuino.
    static let paper = Color(red: 0.99, green: 0.97, blue: 0.91)
    /// Righe della pagina.
    static let rule = Color(red: 0.55, green: 0.66, blue: 0.80).opacity(0.35)
    /// Margine rosso a sinistra.
    static let margin = Color(red: 0.85, green: 0.35, blue: 0.30).opacity(0.45)
    /// Inchiostro blu scuro, come i vestiti di Giallo.
    static let ink = Color(red: 0.13, green: 0.17, blue: 0.29)
    /// Il pelo di un panda rosso.
    static let rust = Color(red: 0.78, green: 0.33, blue: 0.12)
    /// La copertina in cuoio della cronaca.
    static let leather = Color(red: 0.42, green: 0.22, blue: 0.14)
    /// Le lettere dorate impresse sul cuoio.
    static let gilt = Color(red: 0.93, green: 0.80, blue: 0.52)
    /// Il tavolo su cui sono appoggiate le pagine.
    static let desk = Color(red: 0.89, green: 0.86, blue: 0.79)
}

/// Pagina a righe con margine, disegnata dietro le schede.
struct RuledPaper: View {
    var lineSpacing: CGFloat = 22
    var topInset: CGFloat = 44

    var body: some View {
        Canvas { context, size in
            var y = topInset
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.75)), with: .color(Theme.rule))
                y += lineSpacing
            }
            context.fill(Path(CGRect(x: 26, y: 0, width: 1, height: size.height)), with: .color(Theme.margin))
        }
        .background(Theme.paper)
    }
}

/// Carta a puntini per schemi e mappe concettuali.
struct DotGridPaper: View {
    var spacing: CGFloat = 24

    var body: some View {
        Canvas { context, size in
            var y = spacing
            while y < size.height {
                var x = spacing
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                                 with: .color(Theme.rule.opacity(1.6)))
                    x += spacing
                }
                y += spacing
            }
        }
        .background(Theme.paper)
    }
}
