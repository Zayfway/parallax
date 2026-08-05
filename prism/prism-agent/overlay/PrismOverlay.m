// Prism — overlay in-app injecté (façon GameGuardian / Memory Engine).
// UIKit pur en Objective-C, compilé dans le dylib agent. Pilote le moteur
// mémoire Rust (engine.rs) par des fonctions C. Design aligné sur Prism :
// nuit + pervenche, l'ambre = gel/écriture active, mono = valeur machine.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "PrismOverlay.h"

// ── Palette ─────────────────────────────────────────────────────────────────
static UIColor *PXC(uint32_t hex, CGFloat a) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:a];
}
#define NIGHT   0x0A0D18
#define ABYSS   0x131829
#define STRATA  0x1C2338
#define HORIZON 0x2A3352
#define AZIMUTH 0x7C8CFF
#define SIGNAL  0xF5A65B
#define VERDANT 0x4ADE9B
#define ALERT   0xFF6B6B
#define INK     0xF2F4FF
#define INKMUT  0x9AA3C4
#define INKFNT  0x5A6488

static UIFont *PXMono(CGFloat s, UIFontWeight w) { return [UIFont monospacedSystemFontOfSize:s weight:w]; }
static UIFont *PXRound(CGFloat s, UIFontWeight w) {
    UIFont *f = [UIFont systemFontOfSize:s weight:w];
    UIFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return d ? [UIFont fontWithDescriptor:d size:s] : f;
}

static NSDictionary *PXObj(char *c) {
    if (!c) return nil;
    NSString *s = [NSString stringWithUTF8String:c];
    prism_eng_free(c);
    id o = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [o isKindOfClass:[NSDictionary class]] ? o : nil;
}
static NSArray *PXArr(char *c) {
    if (!c) return nil;
    NSString *s = [NSString stringWithUTF8String:c];
    prism_eng_free(c);
    id o = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [o isKindOfClass:[NSArray class]] ? o : nil;
}

// ── Glyphe prisme (dessiné) ─────────────────────────────────────────────────
@interface PrismGlyphView : UIView
@end
@implementation PrismGlyphView
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    CGFloat w = rect.size.width, h = rect.size.height;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat cx = w * 0.42, top = h * 0.20, bot = h * 0.78, half = w * 0.30;
    CGPoint apex = CGPointMake(cx, top), bl = CGPointMake(cx - half, bot), br = CGPointMake(cx + half, bot);
    CGPoint ex = CGPointMake((apex.x + br.x) / 2, (apex.y + br.y) / 2);
    uint32_t sp[6] = {0xFF5A5F, SIGNAL, 0xF5D06B, VERDANT, 0x54D6E0, AZIMUTH};
    CGContextSetLineCap(ctx, kCGLineCapRound);
    for (int i = 0; i < 6; i++) {
        CGFloat a = (8 + i * 7.0) * M_PI / 180.0;
        CGPoint e = CGPointMake(ex.x + w * 0.34 * cos(a), ex.y + w * 0.34 * sin(a));
        CGContextSetStrokeColorWithColor(ctx, PXC(sp[i], 0.95).CGColor);
        CGContextSetLineWidth(ctx, MAX(1.0, w * 0.03));
        CGContextMoveToPoint(ctx, ex.x, ex.y);
        CGContextAddLineToPoint(ctx, e.x, e.y);
        CGContextStrokePath(ctx);
    }
    CGContextSetStrokeColorWithColor(ctx, PXC(0xFFFFFF, 0.9).CGColor);
    CGContextSetLineWidth(ctx, MAX(1.0, w * 0.03));
    CGContextMoveToPoint(ctx, w * 0.06, (apex.y + bl.y) / 2 - h * 0.02);
    CGContextAddLineToPoint(ctx, (apex.x + bl.x) / 2, (apex.y + bl.y) / 2);
    CGContextStrokePath(ctx);
    CGContextSetFillColorWithColor(ctx, PXC(0xFFFFFF, 0.06).CGColor);
    CGContextMoveToPoint(ctx, apex.x, apex.y);
    CGContextAddLineToPoint(ctx, bl.x, bl.y);
    CGContextAddLineToPoint(ctx, br.x, br.y);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    CGContextSetStrokeColorWithColor(ctx, PXC(INK, 0.95).CGColor);
    CGContextSetLineWidth(ctx, MAX(1.2, w * 0.035));
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, apex.x, apex.y);
    CGContextAddLineToPoint(ctx, bl.x, bl.y);
    CGContextAddLineToPoint(ctx, br.x, br.y);
    CGContextClosePath(ctx);
    CGContextStrokePath(ctx);
}
@end

// ── Fenêtre / vue racine à passthrough ──────────────────────────────────────
@interface PrismRootView : UIView
@end
@implementation PrismRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v; // les zones vides laissent passer vers l'app
}
@end

@interface PrismHostVC : UIViewController
@end
@implementation PrismHostVC
- (void)loadView { self.view = [PrismRootView new]; }
- (BOOL)prefersStatusBarHidden { return NO; }
@end

// ── Contrôleur de l'overlay ─────────────────────────────────────────────────
@interface PrismOverlayController : NSObject <UITextFieldDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *floatingButton;
@property (nonatomic, strong) PrismGlyphView *floatGlyph;
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UITextField *writeField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *targetLabel;
@property (nonatomic, strong) UIStackView *candStack;
@property (nonatomic, strong) UIStackView *regionStack;
@property (nonatomic, strong) UISwitch *freezeSwitch;
@property (nonatomic, strong) NSArray<NSNumber *> *sample;
@property (nonatomic, assign) unsigned long long selectedAddr;
@property (nonatomic, assign) BOOL hasSelected;
@property (nonatomic, assign) BOOL open;
@property (nonatomic, assign) NSInteger attempts;
@end

@implementation PrismOverlayController

+ (instancetype)shared {
    static PrismOverlayController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [PrismOverlayController new]; });
    return c;
}

- (UIWindowScene *)activeScene {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *ws = (UIWindowScene *)s;
            if (ws.windows.count > 0) return ws;
        }
    }
    return nil;
}

- (void)tryInstall {
    if (self.window) return;
    UIWindowScene *scene = [self activeScene];
    if (!scene) {
        if (self.attempts++ < 60) {
            __weak typeof(self) ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [ws tryInstall]; });
        }
        return;
    }
    [self installInScene:scene];
}

- (void)installInScene:(UIWindowScene *)scene {
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelAlert + 10;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [PrismHostVC new];
    w.hidden = NO;
    self.window = w;

    [self buildFloatingButton];
    [self buildPanel];
    [self playIntro];
}

// ── Bouton flottant ─────────────────────────────────────────────────────────
- (void)buildFloatingButton {
    CGRect b = self.window.bounds;
    CGFloat d = 58, margin = 14;
    UIView *fb = [[UIView alloc] initWithFrame:CGRectMake(b.size.width - d - margin, b.size.height * 0.42, d, d)];
    fb.layer.cornerRadius = d / 2;
    fb.layer.masksToBounds = NO;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.frame = fb.bounds;
    blur.layer.cornerRadius = d / 2;
    blur.layer.masksToBounds = YES;
    blur.userInteractionEnabled = NO;
    [fb addSubview:blur];

    UIView *tint = [[UIView alloc] initWithFrame:fb.bounds];
    tint.backgroundColor = PXC(ABYSS, 0.55);
    tint.layer.cornerRadius = d / 2;
    tint.layer.borderWidth = 1;
    tint.layer.borderColor = PXC(0xFFFFFF, 0.18).CGColor;
    tint.userInteractionEnabled = NO;
    [fb addSubview:tint];

    PrismGlyphView *g = [[PrismGlyphView alloc] initWithFrame:CGRectInset(fb.bounds, 12, 12)];
    g.userInteractionEnabled = NO;
    [fb addSubview:g];
    self.floatGlyph = g;

    fb.layer.shadowColor = PXC(AZIMUTH, 1).CGColor;
    fb.layer.shadowOffset = CGSizeZero;
    fb.layer.shadowRadius = 14;
    fb.layer.shadowOpacity = 0.0;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
    [fb addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [fb addGestureRecognizer:pan];

    [self.window.rootViewController.view addSubview:fb];
    self.floatingButton = fb;
    fb.alpha = 0;
    fb.transform = CGAffineTransformMakeScale(0.4, 0.4);
}

- (void)startGlow {
    CABasicAnimation *o = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    o.fromValue = @0.35; o.toValue = @0.85; o.duration = 2.2;
    o.autoreverses = YES; o.repeatCount = HUGE_VALF;
    o.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.floatingButton.layer addAnimation:o forKey:@"glow"];
}

- (void)refreshGlowColor {
    BOOL frozen = prism_eng_freeze_count() > 0;
    self.floatingButton.layer.shadowColor = PXC(frozen ? SIGNAL : AZIMUTH, 1).CGColor;
}

- (void)onPan:(UIPanGestureRecognizer *)p {
    UIView *fb = self.floatingButton;
    CGPoint t = [p translationInView:fb.superview];
    fb.center = CGPointMake(fb.center.x + t.x, fb.center.y + t.y);
    [p setTranslation:CGPointZero inView:fb.superview];
    if (p.state == UIGestureRecognizerStateEnded) {
        CGRect b = fb.superview.bounds;
        CGFloat r = fb.bounds.size.width / 2, m = 14;
        CGFloat x = (fb.center.x < b.size.width / 2) ? (m + r) : (b.size.width - m - r);
        CGFloat y = MIN(MAX(fb.center.y, 80), b.size.height - 100);
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.4
                            options:0 animations:^{ fb.center = CGPointMake(x, y); } completion:nil];
    }
}

- (void)onTap {
    if (self.open) [self closePanel]; else [self openPanel];
}

// ── Splash « injecté » ──────────────────────────────────────────────────────
- (void)playIntro {
    UIView *root = self.window.rootViewController.view;
    CGRect b = root.bounds;
    UIView *dim = [[UIView alloc] initWithFrame:b];
    dim.backgroundColor = PXC(NIGHT, 0.0);
    [root addSubview:dim];

    CGFloat gs = 120;
    PrismGlyphView *g = [[PrismGlyphView alloc] initWithFrame:CGRectMake((b.size.width - gs) / 2, b.size.height * 0.36, gs, gs)];
    g.alpha = 0; g.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [dim addSubview:g];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(g.frame) + 10, b.size.width, 30)];
    title.text = @"PRISM"; title.textAlignment = NSTextAlignmentCenter;
    title.font = PXRound(22, UIFontWeightHeavy); title.textColor = PXC(INK, 1);
    title.alpha = 0;
    [dim addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(title.frame) + 2, b.size.width, 20)];
    sub.text = @"agent injecté"; sub.textAlignment = NSTextAlignmentCenter;
    sub.font = PXMono(13, UIFontWeightMedium); sub.textColor = PXC(VERDANT, 1);
    sub.alpha = 0;
    [dim addSubview:sub];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(b.size.width / 2, CGRectGetMaxY(sub.frame) + 16, 0, 3)];
    bar.layer.cornerRadius = 1.5;
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.startPoint = CGPointMake(0, 0.5); grad.endPoint = CGPointMake(1, 0.5);
    grad.colors = @[(id)PXC(0xFF5A5F,1).CGColor,(id)PXC(SIGNAL,1).CGColor,(id)PXC(VERDANT,1).CGColor,(id)PXC(AZIMUTH,1).CGColor];
    grad.frame = CGRectMake(0, 0, 220, 3);
    [bar.layer addSublayer:grad];
    [dim addSubview:bar];

    [UIView animateWithDuration:0.35 animations:^{ dim.backgroundColor = PXC(NIGHT, 0.92); }];
    [UIView animateWithDuration:0.6 delay:0.1 usingSpringWithDamping:0.6 initialSpringVelocity:0.5 options:0 animations:^{
        g.alpha = 1; g.transform = CGAffineTransformIdentity;
    } completion:nil];
    [UIView animateWithDuration:0.4 delay:0.35 options:0 animations:^{ title.alpha = 1; sub.alpha = 1; } completion:nil];
    [UIView animateWithDuration:0.6 delay:0.4 options:UIViewAnimationOptionCurveEaseOut animations:^{
        bar.frame = CGRectMake((b.size.width - 220) / 2, bar.frame.origin.y, 220, 3);
    } completion:nil];

    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.4 animations:^{ dim.alpha = 0; } completion:^(BOOL f) { [dim removeFromSuperview]; }];
        [UIView animateWithDuration:0.7 delay:0.15 usingSpringWithDamping:0.62 initialSpringVelocity:0.5 options:0 animations:^{
            ws.floatingButton.alpha = 1; ws.floatingButton.transform = CGAffineTransformIdentity;
        } completion:^(BOOL f) { [ws startGlow]; [ws refreshGlowColor]; }];
    });
}

// ── Panneau moteur mémoire ──────────────────────────────────────────────────
- (UIButton *)pill:(NSString *)title tint:(uint32_t)tint action:(SEL)sel {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = PXRound(15, UIFontWeightSemibold);
    [btn setTitleColor:PXC(NIGHT, 1) forState:UIControlStateNormal];
    btn.backgroundColor = PXC(tint, 1);
    btn.layer.cornerRadius = 13;
    btn.contentEdgeInsets = UIEdgeInsetsMake(9, 16, 9, 16);
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return btn;
}
- (UIButton *)ghost:(NSString *)title action:(SEL)sel {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = PXMono(16, UIFontWeightBold);
    [btn setTitleColor:PXC(INK, 1) forState:UIControlStateNormal];
    btn.backgroundColor = PXC(STRATA, 0.7);
    btn.layer.cornerRadius = 12;
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [btn.widthAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
    [btn.heightAnchor constraintEqualToConstant:38].active = YES;
    return btn;
}
- (UITextField *)fieldPlaceholder:(NSString *)ph {
    UITextField *tf = [UITextField new];
    tf.attributedPlaceholder = [[NSAttributedString alloc] initWithString:ph attributes:@{NSForegroundColorAttributeName: PXC(INKFNT, 1)}];
    tf.font = PXMono(15, UIFontWeightMedium);
    tf.textColor = PXC(INK, 1);
    tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    tf.keyboardAppearance = UIKeyboardAppearanceDark;
    tf.backgroundColor = PXC(NIGHT, 0.55);
    tf.layer.cornerRadius = 12;
    tf.layer.borderWidth = 1;
    tf.layer.borderColor = PXC(HORIZON, 1).CGColor;
    tf.delegate = self;
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    tf.leftView = pad; tf.leftViewMode = UITextFieldViewModeAlways;
    [tf.heightAnchor constraintEqualToConstant:42].active = YES;
    return tf;
}
- (UILabel *)sectionLabel:(NSString *)t {
    UILabel *l = [UILabel new];
    l.text = [t uppercaseString];
    l.font = PXRound(12, UIFontWeightBold);
    l.textColor = PXC(INKFNT, 1);
    return l;
}

- (void)buildPanel {
    CGRect b = self.window.bounds;
    CGFloat ph = b.size.height * 0.66;

    UIView *back = [[UIView alloc] initWithFrame:b];
    back.backgroundColor = PXC(0x000000, 0.0);
    UITapGestureRecognizer *bt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closePanel)];
    [back addGestureRecognizer:bt];
    back.alpha = 0; back.hidden = YES;
    [self.window.rootViewController.view addSubview:back];
    self.backdrop = back;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height, b.size.width, ph)];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    blur.frame = panel.bounds; blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [panel addSubview:blur];
    UIView *tint = [[UIView alloc] initWithFrame:panel.bounds];
    tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tint.backgroundColor = PXC(ABYSS, 0.72);
    [panel addSubview:tint];
    panel.layer.cornerRadius = 26;
    panel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    panel.layer.masksToBounds = YES;
    [self.window.rootViewController.view addSubview:panel];
    self.panel = panel;

    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, panel.bounds.size.width, ph)];
    sc.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sc.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    sc.showsVerticalScrollIndicator = NO;
    [panel addSubview:sc];
    self.scroll = sc;

    UIStackView *st = [UIStackView new];
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 12;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [sc addSubview:st];
    self.stack = st;
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:sc.contentLayoutGuide.topAnchor constant:16],
        [st.bottomAnchor constraintEqualToAnchor:sc.contentLayoutGuide.bottomAnchor constant:-28],
        [st.leadingAnchor constraintEqualToAnchor:sc.frameLayoutGuide.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:sc.frameLayoutGuide.trailingAnchor constant:-16],
    ]];

    // En-tête
    UIStackView *head = [[UIStackView alloc] init];
    head.axis = UILayoutConstraintAxisHorizontal; head.alignment = UIStackViewAlignmentCenter; head.spacing = 8;
    PrismGlyphView *hg = [[PrismGlyphView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
    [hg.widthAnchor constraintEqualToConstant:26].active = YES; [hg.heightAnchor constraintEqualToConstant:26].active = YES;
    UILabel *ht = [UILabel new]; ht.text = @"Prism"; ht.font = PXRound(22, UIFontWeightHeavy); ht.textColor = PXC(INK, 1);
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = PXRound(18, UIFontWeightBold);
    [close setTitleColor:PXC(INKMUT, 1) forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [head addArrangedSubview:hg]; [head addArrangedSubview:ht];
    UIView *spacer = [UIView new]; [head addArrangedSubview:spacer];
    [head addArrangedSubview:close];
    [st addArrangedSubview:head];

    // Recherche
    [st addArrangedSubview:[self sectionLabel:@"Recherche"]];
    self.searchField = [self fieldPlaceholder:@"valeur int32"];
    UIStackView *srow = [[UIStackView alloc] initWithArrangedSubviews:@[self.searchField, [self pill:@"Rechercher" tint:AZIMUTH action:@selector(onSearch)]]];
    srow.axis = UILayoutConstraintAxisHorizontal; srow.spacing = 8; srow.distribution = UIStackViewDistributionFill;
    [self.searchField setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [st addArrangedSubview:srow];

    self.statusLabel = [UILabel new];
    self.statusLabel.font = PXMono(12, UIFontWeightMedium); self.statusLabel.textColor = PXC(INKMUT, 1);
    self.statusLabel.text = @"prêt — saisis une valeur";
    [st addArrangedSubview:self.statusLabel];

    // Affiner
    [st addArrangedSubview:[self sectionLabel:@"Affiner"]];
    UIStackView *rrow = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self ghost:@"=" action:@selector(onRefineEq)],
        [self ghost:@"▲" action:@selector(onRefineUp)],
        [self ghost:@"▼" action:@selector(onRefineDown)],
        [self ghost:@"≈" action:@selector(onRefineSame)],
    ]];
    rrow.axis = UILayoutConstraintAxisHorizontal; rrow.spacing = 8; rrow.distribution = UIStackViewDistributionFillEqually;
    [st addArrangedSubview:rrow];

    // Candidats
    [st addArrangedSubview:[self sectionLabel:@"Candidats"]];
    self.candStack = [UIStackView new]; self.candStack.axis = UILayoutConstraintAxisVertical; self.candStack.spacing = 6;
    [st addArrangedSubview:self.candStack];

    // Écrire
    [st addArrangedSubview:[self sectionLabel:@"Écrire"]];
    self.targetLabel = [UILabel new]; self.targetLabel.font = PXMono(13, UIFontWeightSemibold); self.targetLabel.textColor = PXC(INKFNT, 1);
    self.targetLabel.text = @"aucune adresse sélectionnée";
    [st addArrangedSubview:self.targetLabel];
    self.writeField = [self fieldPlaceholder:@"nouvelle valeur"];
    UIStackView *wrow = [[UIStackView alloc] initWithArrangedSubviews:@[self.writeField, [self pill:@"Écrire" tint:SIGNAL action:@selector(onWrite)]]];
    wrow.axis = UILayoutConstraintAxisHorizontal; wrow.spacing = 8;
    [st addArrangedSubview:wrow];

    UIStackView *frow = [[UIStackView alloc] init];
    frow.axis = UILayoutConstraintAxisHorizontal; frow.alignment = UIStackViewAlignmentCenter; frow.spacing = 8;
    UILabel *fl = [UILabel new]; fl.text = @"Figer (freeze)"; fl.font = PXRound(15, UIFontWeightMedium); fl.textColor = PXC(INK, 1);
    self.freezeSwitch = [UISwitch new]; self.freezeSwitch.onTintColor = PXC(SIGNAL, 1);
    [self.freezeSwitch addTarget:self action:@selector(onFreeze) forControlEvents:UIControlEventValueChanged];
    [frow addArrangedSubview:fl]; UIView *fs = [UIView new]; [frow addArrangedSubview:fs]; [frow addArrangedSubview:self.freezeSwitch];
    [st addArrangedSubview:frow];

    // Régions
    UIStackView *reghead = [[UIStackView alloc] init]; reghead.axis = UILayoutConstraintAxisHorizontal; reghead.alignment = UIStackViewAlignmentCenter;
    UILabel *rl = [self sectionLabel:@"Régions"]; [reghead addArrangedSubview:rl];
    UIView *rspace = [UIView new]; [reghead addArrangedSubview:rspace];
    [reghead addArrangedSubview:[self pill:@"Charger" tint:AZIMUTH action:@selector(onRegions)]];
    [st addArrangedSubview:reghead];
    self.regionStack = [UIStackView new]; self.regionStack.axis = UILayoutConstraintAxisVertical; self.regionStack.spacing = 6;
    [st addArrangedSubview:self.regionStack];
}

- (void)openPanel {
    self.open = YES;
    [self.window.rootViewController.view bringSubviewToFront:self.backdrop];
    [self.window.rootViewController.view bringSubviewToFront:self.panel];
    self.backdrop.hidden = NO;
    CGRect b = self.window.bounds; CGFloat ph = self.panel.bounds.size.height;
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.4 options:0 animations:^{
        self.backdrop.alpha = 1; self.backdrop.backgroundColor = PXC(0x000000, 0.45);
        self.panel.frame = CGRectMake(0, b.size.height - ph, b.size.width, ph);
    } completion:nil];
}
- (void)closePanel {
    self.open = NO;
    [self.window endEditing:YES];
    CGRect b = self.window.bounds;
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.3 options:0 animations:^{
        self.backdrop.alpha = 0;
        self.panel.frame = CGRectMake(0, b.size.height, b.size.width, self.panel.bounds.size.height);
    } completion:^(BOOL f) { self.backdrop.hidden = YES; }];
}

// ── Actions moteur ──────────────────────────────────────────────────────────
- (int)searchValue { return [self.searchField.text intValue]; }

- (void)applyScanJson:(NSDictionary *)d verb:(NSString *)verb {
    NSInteger count = [d[@"count"] integerValue];
    self.sample = d[@"sample"] ?: @[];
    self.statusLabel.textColor = count > 0 ? PXC(AZIMUTH, 1) : PXC(INKMUT, 1);
    self.statusLabel.text = [NSString stringWithFormat:@"%@ — %ld adresse%@ candidate%@", verb, (long)count, count > 1 ? @"s" : @"", count > 1 ? @"s" : @""];
    [self renderCandidates];
}

- (void)onSearch {
    [self.window endEditing:YES];
    NSDictionary *d = PXObj(prism_eng_scan_i32([self searchValue]));
    if (d) [self applyScanJson:d verb:@"recherche"];
}
- (void)refine:(unsigned char)op {
    NSDictionary *d = PXObj(prism_eng_refine(op, [self searchValue]));
    if (d) [self applyScanJson:d verb:@"affiné"];
}
- (void)onRefineEq { [self refine:0]; }
- (void)onRefineUp { [self refine:1]; }
- (void)onRefineDown { [self refine:2]; }
- (void)onRefineSame { [self refine:3]; }

- (void)renderCandidates {
    for (UIView *v in self.candStack.arrangedSubviews) { [v removeFromSuperview]; }
    NSInteger shown = MIN((NSInteger)self.sample.count, 40);
    for (NSInteger i = 0; i < shown; i++) {
        unsigned long long addr = [self.sample[i] unsignedLongLongValue];
        int val = 0; prism_eng_read_i32(addr, &val);
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        row.tag = i;
        [row setTitle:[NSString stringWithFormat:@"0x%010llX      %d", addr, val] forState:UIControlStateNormal];
        row.titleLabel.font = PXMono(13, UIFontWeightMedium);
        [row setTitleColor:PXC(INK, 1) forState:UIControlStateNormal];
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        row.contentEdgeInsets = UIEdgeInsetsMake(9, 12, 9, 12);
        row.backgroundColor = (self.hasSelected && self.selectedAddr == addr) ? PXC(AZIMUTH, 0.22) : PXC(NIGHT, 0.4);
        row.layer.cornerRadius = 10;
        [row addTarget:self action:@selector(onCandidate:) forControlEvents:UIControlEventTouchUpInside];
        [self.candStack addArrangedSubview:row];
    }
    if ((NSInteger)self.sample.count == 0) {
        UILabel *e = [UILabel new]; e.text = @"—"; e.font = PXMono(13, UIFontWeightRegular); e.textColor = PXC(INKFNT, 1);
        [self.candStack addArrangedSubview:e];
    }
}
- (void)onCandidate:(UIButton *)b {
    if (b.tag < 0 || b.tag >= (NSInteger)self.sample.count) return;
    self.selectedAddr = [self.sample[b.tag] unsignedLongLongValue];
    self.hasSelected = YES;
    int val = 0; prism_eng_read_i32(self.selectedAddr, &val);
    self.targetLabel.textColor = PXC(INK, 1);
    self.targetLabel.text = [NSString stringWithFormat:@"cible : 0x%010llX  =  %d", self.selectedAddr, val];
    [self renderCandidates];
}

- (void)onWrite {
    if (!self.hasSelected) { self.targetLabel.textColor = PXC(ALERT, 1); self.targetLabel.text = @"choisis une adresse d'abord"; return; }
    int v = [self.writeField.text intValue];
    int rc = prism_eng_write_i32(self.selectedAddr, v);
    int back = v; prism_eng_read_i32(self.selectedAddr, &back);
    self.targetLabel.textColor = rc == 0 ? PXC(VERDANT, 1) : PXC(ALERT, 1);
    self.targetLabel.text = rc == 0
        ? [NSString stringWithFormat:@"écrit : 0x%010llX  =  %d", self.selectedAddr, back]
        : @"écriture refusée";
    if (rc == 0 && self.freezeSwitch.on) { prism_eng_freeze_add(self.selectedAddr, v); }
    [self flashWrite];
}

- (void)flashWrite {
    [self refreshGlowColor];
    UIView *fb = self.floatingButton;
    [UIView animateWithDuration:0.15 animations:^{ fb.transform = CGAffineTransformMakeScale(1.18, 1.18); } completion:^(BOOL f) {
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.6 options:0 animations:^{
            fb.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
}

- (void)onFreeze {
    if (self.freezeSwitch.on) {
        if (self.hasSelected) { prism_eng_freeze_add(self.selectedAddr, [self.writeField.text intValue]); }
    } else {
        prism_eng_freeze_clear();
    }
    [self refreshGlowColor];
}

- (void)onRegions {
    for (UIView *v in self.regionStack.arrangedSubviews) { [v removeFromSuperview]; }
    NSArray *regs = PXArr(prism_eng_regions());
    NSInteger shown = MIN((NSInteger)regs.count, 60);
    for (NSInteger i = 0; i < shown; i++) {
        NSDictionary *r = regs[i];
        unsigned long long addr = [r[@"addr"] unsignedLongLongValue];
        unsigned long long size = [r[@"size"] unsignedLongLongValue];
        int prot = [r[@"prot"] intValue];
        NSString *ps = [NSString stringWithFormat:@"%@%@%@", (prot & 1) ? @"r" : @"-", (prot & 2) ? @"w" : @"-", (prot & 4) ? @"x" : @"-"];
        UILabel *l = [UILabel new];
        l.font = PXMono(12, UIFontWeightMedium); l.textColor = PXC(INKMUT, 1);
        l.text = [NSString stringWithFormat:@"0x%010llX   %@   %@", addr, ps, [self humanSize:size]];
        [self.regionStack addArrangedSubview:l];
    }
    UILabel *tot = [UILabel new]; tot.font = PXMono(12, UIFontWeightRegular); tot.textColor = PXC(INKFNT, 1);
    tot.text = [NSString stringWithFormat:@"%lu régions", (unsigned long)regs.count];
    [self.regionStack addArrangedSubview:tot];
}
- (NSString *)humanSize:(unsigned long long)n {
    const char *u[] = {"o", "Ko", "Mo", "Go"}; double v = (double)n; int i = 0;
    while (v >= 1024 && i < 3) { v /= 1024; i++; }
    return [NSString stringWithFormat:(v < 10 && i > 0) ? @"%.1f%s" : @"%.0f%s", v, u[i]];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
@end

// ── Point d'entrée (appelé par le ctor Rust) ────────────────────────────────
void prism_overlay_bootstrap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [[PrismOverlayController shared] tryInstall];
        });
    });
}
