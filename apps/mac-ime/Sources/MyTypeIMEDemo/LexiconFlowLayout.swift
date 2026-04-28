import AppKit

final class LexiconFlowLayout: NSView {
    private var subviewConstraints: [NSLayoutConstraint] = []
    
    var spacing: CGFloat = 8 {
        didSet { needsLayout = true }
    }
    
    var maxColumns: Int = 4 {
        didSet { needsLayout = true }
    }
    
    override var isFlipped: Bool { true }
    
    override func layout() {
        super.layout()
        
        guard !subviews.isEmpty else { return }
        let totalSpacing = spacing * CGFloat(maxColumns - 1)
        let itemWidth = (bounds.width - totalSpacing) / CGFloat(maxColumns)
        
        var xOffset: CGFloat = 0
        var yOffset: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        var col = 0
        
        for view in subviews {
            view.frame = NSRect(x: xOffset, y: yOffset, width: itemWidth, height: view.fittingSize.height)
            rowHeight = max(rowHeight, view.frame.height)
            
            xOffset += itemWidth + spacing
            col += 1
            
            if col >= maxColumns {
                col = 0
                xOffset = 0
                yOffset += rowHeight + spacing
                rowHeight = 0
            }
        }
    }
    
    override var intrinsicContentSize: NSSize {
        guard !subviews.isEmpty else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        
        let totalSpacing = spacing * CGFloat(maxColumns - 1)
        let itemWidth = (bounds.width > 0 ? bounds.width : 500 - totalSpacing) / CGFloat(maxColumns)
        
        var yOffset: CGFloat = 0
        var rowHeight: CGFloat = 0
        var col = 0
        
        for view in subviews {
            rowHeight = max(rowHeight, view.fittingSize.height)
            col += 1
            if col >= maxColumns {
                col = 0
                yOffset += rowHeight + spacing
                rowHeight = 0
            }
        }
        
        if col > 0 {
            yOffset += rowHeight
        } else {
            yOffset -= spacing
        }
        
        return NSSize(width: NSView.noIntrinsicMetric, height: max(0, yOffset))
    }
}
