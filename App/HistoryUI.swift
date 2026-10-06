import UIKit

@MainActor
enum HistoryUI {
    static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red:0.63,green:0.70,blue:1,alpha:1) : UIColor(red:0.29,green:0.38,blue:0.78,alpha:1)
    }
    static func label(_ text:String? = nil, style:UIFont.TextStyle = .body, color:UIColor = .label, weight:UIFont.Weight? = nil) -> UILabel {
        let label=UILabel();label.text=text;label.textColor=color;label.numberOfLines=0;label.adjustsFontForContentSizeCategory=true
        let base=UIFont.preferredFont(forTextStyle:style,compatibleWith:UITraitCollection(preferredContentSizeCategory:.large))
        label.font=weight.map { UIFontMetrics(forTextStyle:style).scaledFont(for: .systemFont(ofSize:base.pointSize,weight:$0)) } ?? base
        return label
    }
    static func stack(_ views:[UIView], spacing:CGFloat = 12, axis:NSLayoutConstraint.Axis = .vertical) -> UIStackView {
        let stack=UIStackView(arrangedSubviews:views);stack.axis=axis;stack.spacing=spacing;return stack
    }
    static func inset(_ content:UIView, into container:UIView, amount:CGFloat = 20) {
        content.translatesAutoresizingMaskIntoConstraints=false;container.addSubview(content)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo:container.topAnchor,constant:amount),
            content.bottomAnchor.constraint(equalTo:container.bottomAnchor,constant:-amount),
            content.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:amount),
            content.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-amount)])
    }
    static func card(_ content:UIView, inset:CGFloat = 20) -> UIView {
        let card=UIView();card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius=26;card.layer.cornerCurve = .continuous
        self.inset(content,into:card,amount:inset);return card
    }
    static func separator() -> UIView {
        let line=UIView();line.backgroundColor = .separator
        line.heightAnchor.constraint(equalToConstant:1/UIScreen.main.scale).isActive=true;return line
    }
    static func menuRow(title:String, subtitle:String, symbol:String, target:Any, action:Selector, subtitleView:UILabel? = nil) -> UIControl {
        let row=UIControl();row.backgroundColor = .secondarySystemGroupedBackground
        row.layer.cornerRadius=24;row.layer.cornerCurve = .continuous
        let icon=UIImageView(image:UIImage(systemName:symbol));icon.tintColor=accent;icon.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant:28),icon.heightAnchor.constraint(equalToConstant:28)])
        let labels=stack([label(title,style:.headline),subtitleView ?? label(subtitle,style:.subheadline,color:.secondaryLabel)],spacing:3)
        let chevron=UIImageView(image:UIImage(systemName:"chevron.right"));chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = .init(pointSize:12,weight:.semibold)
        chevron.widthAnchor.constraint(equalToConstant:9).isActive=true
        let content=stack([icon,labels,chevron],spacing:15,axis:.horizontal);content.alignment = .center;content.isUserInteractionEnabled=false
        inset(content,into:row,amount:20);row.addTarget(target,action:action,for:.touchUpInside)
        row.isAccessibilityElement=true;row.accessibilityLabel=title;row.accessibilityValue=subtitle;row.accessibilityTraits = .button
        return row
    }
    static func sheetHeading(_ title:String, on item:UINavigationItem) {
        item.title=title
        item.largeTitleDisplayMode = .never
        item.titleView=UIView()
        let heading=label(title,style:.largeTitle,weight:.bold)
        heading.font=UIFontMetrics(forTextStyle:.largeTitle).scaledFont(for:.systemFont(ofSize:34,weight:.bold),maximumPointSize:40)
        heading.accessibilityTraits = .header
        let container=UIView();heading.translatesAutoresizingMaskIntoConstraints=false;container.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:8),
            heading.trailingAnchor.constraint(equalTo:container.trailingAnchor),
            heading.topAnchor.constraint(equalTo:container.topAnchor),
            heading.bottomAnchor.constraint(equalTo:container.bottomAnchor)])
        let titleItem=UIBarButtonItem(customView:container)
        if #available(iOS 26.0, *) { titleItem.hidesSharedBackground=true }
        item.leftBarButtonItem=titleItem
    }
    static func sheet(_ controller:UIViewController) -> UINavigationController {
        let nav=UINavigationController(rootViewController:controller)
        nav.navigationBar.prefersLargeTitles=true;nav.view.tintColor=accent
        return nav
    }
}

@MainActor
final class HistoryTintCard: UIView {
    private let gradient=CAGradientLayer()
    override init(frame:CGRect) {
        super.init(frame:frame);layer.cornerRadius=28;layer.cornerCurve = .continuous;clipsToBounds=true
        gradient.startPoint=CGPoint(x:0,y:0);gradient.endPoint=CGPoint(x:1,y:1);layer.insertSublayer(gradient,at:0)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view:HistoryTintCard, _:UITraitCollection) in view.updateColors() }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews();CATransaction.begin();CATransaction.setDisableActions(true);gradient.frame=bounds;CATransaction.commit() }
    private func updateColors() {
        gradient.colors=traitCollection.userInterfaceStyle == .dark ? [UIColor(red:0.13,green:0.18,blue:0.29,alpha:1).cgColor,UIColor(red:0.18,green:0.16,blue:0.29,alpha:1).cgColor] : [UIColor(red:0.88,green:0.95,blue:0.99,alpha:1).cgColor,UIColor(red:0.93,green:0.91,blue:0.99,alpha:1).cgColor]
    }
}
