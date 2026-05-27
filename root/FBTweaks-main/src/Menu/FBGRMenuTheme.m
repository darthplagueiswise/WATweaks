#import "FBGRMenuTheme.h"
UIColor *FBGRBg(void)   { return [UIColor colorWithRed:.04 green:.04 blue:.06 alpha:1]; }
UIColor *FBGRCell(void) { return [UIColor colorWithRed:.11 green:.11 blue:.13 alpha:1]; }
UIColor *FBGRText(void) { return UIColor.whiteColor; }
UIColor *FBGRSub(void)  { return [UIColor colorWithWhite:.55 alpha:1]; }
UIColor *FBGRAccent(NSInteger i) {
    static NSArray *p; static dispatch_once_t o;
    dispatch_once(&o, ^{
        p = @[UIColor.systemCyanColor, UIColor.systemPurpleColor, UIColor.systemOrangeColor,
              UIColor.systemGreenColor, UIColor.systemBlueColor,  UIColor.systemPinkColor,
              UIColor.systemYellowColor, UIColor.systemTealColor];
    });
    return p[(NSUInteger)labs((long)i) % p.count];
}
UIColor *FBGRAccentForProvider(NSString *c) {
    NSDictionary *m = @{@"cyan":UIColor.systemCyanColor, @"purple":UIColor.systemPurpleColor,
        @"orange":UIColor.systemOrangeColor, @"green":UIColor.systemGreenColor,
        @"blue":UIColor.systemBlueColor, @"pink":UIColor.systemPinkColor,
        @"teal":UIColor.systemTealColor};
    return m[c ?: @""] ?: UIColor.systemBlueColor;
}
void FBGRApplyTable(UITableView *tv, UIViewController *vc) {
    if (vc) vc.view.backgroundColor = FBGRBg();
    if (!tv) return;
    tv.backgroundColor = FBGRBg();
    tv.separatorColor  = [UIColor colorWithWhite:.22 alpha:1];
    tv.separatorInset  = UIEdgeInsetsZero;
}
void FBGRApplyCell(UITableViewCell *c, NSInteger idx, NSString *color) {
    c.backgroundColor = FBGRCell();
    c.textLabel.textColor = FBGRText();
    c.detailTextLabel.textColor = FBGRSub();
    c.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    c.detailTextLabel.font = [UIFont systemFontOfSize:12];
    c.tintColor = color ? FBGRAccentForProvider(color) : FBGRAccent(idx);
    c.selectedBackgroundView = [[UIView alloc] init];
    c.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:.18 alpha:1];
}
UIImage *FBGRSymbol(NSString *name, UIColor *tint) {
    UIImage *img = [UIImage systemImageNamed:name ?: @"circle"];
    if (tint) img = [img imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
    return img;
}
