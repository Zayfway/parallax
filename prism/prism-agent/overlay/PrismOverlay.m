// Prism — overlay in-app injecté (façon GameGuardian / Memory Engine).
// UIKit natif (SF Symbols, matériaux système, UIButtonConfiguration, UIMenu),
// forcé en thème sombre. Pilote le moteur mémoire typé Rust (engine.rs) par
// des fonctions C. Barre-pilule flottante -> feuille Scan / Enregistrés / Régions.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "PrismOverlay.h"

// État global lu par le hit-testing passthrough (évite les soucis d'ordre de
// déclaration). Panneau fermé -> seule la barre-pilule capte les touches.
static BOOL gPrismOpen = NO;
static __weak UIView *gPrismBar = nil;

// ── Couleurs (système Apple + accents) ──────────────────────────────────────
#define ACCENT   (UIColor.systemBlueColor)
#define FREEZEC  (UIColor.systemOrangeColor)
#define OKC      (UIColor.systemGreenColor)
#define BADC     (UIColor.systemRedColor)

static UIFont *PXMono(CGFloat s, UIFontWeight w) { return [UIFont monospacedSystemFontOfSize:s weight:w]; }
static UIFont *PXText(CGFloat s, UIFontWeight w) { return [UIFont systemFontOfSize:s weight:w]; }

static NSString *PXStr(char *c) {
    if (!c) return @"";
    NSString *s = [NSString stringWithUTF8String:c];
    prism_eng_free(c);
    return s ?: @"";
}
static NSDictionary *PXObj(char *c) {
    NSString *s = PXStr(c);
    id o = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [o isKindOfClass:[NSDictionary class]] ? o : nil;
}
static NSArray *PXArr(char *c) {
    NSString *s = PXStr(c);
    id o = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [o isKindOfClass:[NSArray class]] ? o : nil;
}

// ── Glyphe prisme ───────────────────────────────────────────────────────────
@interface PrismGlyphView : UIView
@end
@implementation PrismGlyphView
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) { self.backgroundColor = UIColor.clearColor; self.opaque = NO; }
    return self;
}
- (void)drawRect:(CGRect)rect {
    CGFloat w = rect.size.width, h = rect.size.height;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat cx = w * 0.42, top = h * 0.20, bot = h * 0.78, half = w * 0.30;
    CGPoint apex = CGPointMake(cx, top), bl = CGPointMake(cx - half, bot), br = CGPointMake(cx + half, bot);
    CGPoint ex = CGPointMake((apex.x + br.x) / 2, (apex.y + br.y) / 2);
    UIColor *sp[6] = { [UIColor colorWithRed:1 green:0.35 blue:0.37 alpha:1], FREEZEC,
                       [UIColor colorWithRed:0.96 green:0.82 blue:0.42 alpha:1], OKC,
                       [UIColor colorWithRed:0.33 green:0.84 blue:0.88 alpha:1], ACCENT };
    CGContextSetLineCap(ctx, kCGLineCapRound);
    for (int i = 0; i < 6; i++) {
        CGFloat a = (8 + i * 7.0) * M_PI / 180.0;
        CGPoint e = CGPointMake(ex.x + w * 0.34 * cos(a), ex.y + w * 0.34 * sin(a));
        CGContextSetStrokeColorWithColor(ctx, sp[i].CGColor);
        CGContextSetLineWidth(ctx, MAX(1.0, w * 0.03));
        CGContextMoveToPoint(ctx, ex.x, ex.y); CGContextAddLineToPoint(ctx, e.x, e.y); CGContextStrokePath(ctx);
    }
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.9].CGColor);
    CGContextSetLineWidth(ctx, MAX(1.0, w * 0.03));
    CGContextMoveToPoint(ctx, w * 0.06, (apex.y + bl.y) / 2 - h * 0.02);
    CGContextAddLineToPoint(ctx, (apex.x + bl.x) / 2, (apex.y + bl.y) / 2); CGContextStrokePath(ctx);
    CGContextSetStrokeColorWithColor(ctx, UIColor.labelColor.CGColor);
    CGContextSetLineWidth(ctx, MAX(1.2, w * 0.035)); CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, apex.x, apex.y); CGContextAddLineToPoint(ctx, bl.x, bl.y);
    CGContextAddLineToPoint(ctx, br.x, br.y); CGContextClosePath(ctx); CGContextStrokePath(ctx);
}
@end

// ── Fenêtre passthrough ─────────────────────────────────────────────────────
@interface PrismRootView : UIView
@end
@implementation PrismRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self) return nil;          // zone vide -> passe à l'app
    if (gPrismOpen) return hit;                    // panneau ouvert -> modal, on capte
    // Panneau fermé : ne capter QUE la barre-pilule ; tout le reste passe à l'app.
    for (UIView *v = hit; v; v = v.superview) {
        if (v == gPrismBar) return hit;
    }
    return nil;
}
@end
@interface PrismHostVC : UIViewController
@end
@implementation PrismHostVC
- (void)loadView { self.view = [PrismRootView new]; }
@end

// ── Contrôleur ──────────────────────────────────────────────────────────────
@interface PrismOverlayController : NSObject <UITextFieldDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIVisualEffectView *bar;
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIVisualEffectView *sheet;
@property (nonatomic, strong) UISegmentedControl *segment;
@property (nonatomic, strong) UIStackView *content;
@property (nonatomic, strong) UIButton *typeButton;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UITextField *writeField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *targetLabel;
@property (nonatomic, strong) UIStackView *candBox;
@property (nonatomic, strong) UIStackView *savedBox;
@property (nonatomic, strong) NSArray<NSNumber *> *sample;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *saved;      // @{ty,addr}
@property (nonatomic, strong) NSMutableArray<UILabel *> *savedValueLabels;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) NSInteger currentType;
@property (nonatomic, assign) unsigned long long selectedAddr;
@property (nonatomic, assign) BOOL hasSelected;
@property (nonatomic, assign) BOOL open;
@property (nonatomic, assign) NSInteger tab;
@property (nonatomic, assign) NSInteger attempts;
@property (nonatomic, assign) CGFloat sheetH;
@end

@implementation PrismOverlayController

+ (instancetype)shared {
    static PrismOverlayController *c; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [PrismOverlayController new]; c.currentType = 2; c.saved = [NSMutableArray array]; });
    return c;
}
- (NSArray<NSString *> *)typeNames { return @[@"i8", @"i16", @"i32", @"i64", @"u8", @"u16", @"u32", @"u64", @"float", @"double"]; }

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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws tryInstall]; });
        }
        return;
    }
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelAlert + 10;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [PrismHostVC new];
    w.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    w.hidden = NO;
    self.window = w;
    [self buildBar];
    [self buildSheet];
    [self playIntro];
}

// ── Barre-pilule flottante ──────────────────────────────────────────────────
- (UIButton *)barIcon:(NSString *)sym action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *ic = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    [b setImage:[UIImage systemImageNamed:sym withConfiguration:ic] forState:UIControlStateNormal];
    b.tintColor = ACCENT;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)buildBar {
    CGRect b = self.window.bounds;
    CGFloat h = 50, wdt = 210;
    UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    bar.frame = CGRectMake(b.size.width - wdt - 12, b.size.height * 0.40, wdt, h);
    bar.layer.cornerRadius = h / 2; bar.layer.masksToBounds = YES;
    bar.layer.borderWidth = 0.5; bar.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;

    UIView *brand = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 34, 34)];
    PrismGlyphView *g = [[PrismGlyphView alloc] initWithFrame:CGRectMake(3, 3, 28, 28)];
    g.userInteractionEnabled = NO; [brand addSubview:g];
    UITapGestureRecognizer *bt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleSheet)];
    [brand addGestureRecognizer:bt];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[
        brand,
        [self barIcon:@"magnifyingglass" action:@selector(openScan)],
        [self barIcon:@"bookmark.fill" action:@selector(openSaved)],
        [self barIcon:@"square.grid.2x2.fill" action:@selector(openRegions)],
    ]];
    row.frame = bar.contentView.bounds;
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    row.axis = UILayoutConstraintAxisHorizontal; row.distribution = UIStackViewDistributionFillEqually; row.alignment = UIStackViewAlignmentCenter;
    row.layoutMarginsRelativeArrangement = YES; row.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 12, 0, 12);
    [bar.contentView addSubview:row];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [bar addGestureRecognizer:pan];

    bar.alpha = 0; bar.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [self.window.rootViewController.view addSubview:bar];
    self.bar = bar;
    gPrismBar = bar;
}
- (void)onPan:(UIPanGestureRecognizer *)p {
    UIView *v = self.bar;
    CGPoint t = [p translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [p setTranslation:CGPointZero inView:v.superview];
    if (p.state == UIGestureRecognizerStateEnded) {
        CGRect b = v.superview.bounds; CGFloat m = 12;
        CGFloat x = (v.center.x < b.size.width / 2) ? (m + v.bounds.size.width / 2) : (b.size.width - m - v.bounds.size.width / 2);
        CGFloat y = MIN(MAX(v.center.y, 80), b.size.height - 120);
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.4 options:0 animations:^{ v.center = CGPointMake(x, y); } completion:nil];
    }
}

// ── Splash « injecté » ──────────────────────────────────────────────────────
- (void)playIntro {
    UIView *root = self.window.rootViewController.view; CGRect b = root.bounds;
    UIView *dim = [[UIView alloc] initWithFrame:b]; dim.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0];
    [root addSubview:dim];
    CGFloat gs = 118;
    PrismGlyphView *g = [[PrismGlyphView alloc] initWithFrame:CGRectMake((b.size.width - gs) / 2, b.size.height * 0.36, gs, gs)];
    g.alpha = 0; g.transform = CGAffineTransformMakeScale(0.6, 0.6); [dim addSubview:g];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(g.frame) + 10, b.size.width, 30)];
    t.text = @"PRISM"; t.textAlignment = NSTextAlignmentCenter; t.font = PXText(22, UIFontWeightHeavy); t.textColor = UIColor.labelColor; t.alpha = 0; [dim addSubview:t];
    UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(t.frame) + 2, b.size.width, 20)];
    s.text = @"agent injecté"; s.textAlignment = NSTextAlignmentCenter; s.font = PXMono(13, UIFontWeightMedium); s.textColor = OKC; s.alpha = 0; [dim addSubview:s];
    [UIView animateWithDuration:0.35 animations:^{ dim.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0.92]; }];
    [UIView animateWithDuration:0.6 delay:0.1 usingSpringWithDamping:0.6 initialSpringVelocity:0.5 options:0 animations:^{ g.alpha = 1; g.transform = CGAffineTransformIdentity; } completion:nil];
    [UIView animateWithDuration:0.4 delay:0.35 options:0 animations:^{ t.alpha = 1; s.alpha = 1; } completion:nil];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.4 animations:^{ dim.alpha = 0; } completion:^(BOOL f) { [dim removeFromSuperview]; }];
        [UIView animateWithDuration:0.7 delay:0.1 usingSpringWithDamping:0.62 initialSpringVelocity:0.5 options:0 animations:^{ ws.bar.alpha = 1; ws.bar.transform = CGAffineTransformIdentity; } completion:nil];
    });
}

// ── Feuille ─────────────────────────────────────────────────────────────────
- (void)buildSheet {
    CGRect b = self.window.bounds;
    self.sheetH = b.size.height * 0.68;
    UIView *back = [[UIView alloc] initWithFrame:b]; back.backgroundColor = [UIColor colorWithWhite:0 alpha:0]; back.alpha = 0; back.hidden = YES;
    [back addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeSheet)]];
    [self.window.rootViewController.view addSubview:back]; self.backdrop = back;

    UIVisualEffectView *sheet = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
    sheet.frame = CGRectMake(0, b.size.height, b.size.width, self.sheetH);
    sheet.layer.cornerRadius = 24; sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner; sheet.layer.masksToBounds = YES;
    [self.window.rootViewController.view addSubview:sheet]; self.sheet = sheet;
    UIView *cv = sheet.contentView;

    UIView *grab = [[UIView alloc] initWithFrame:CGRectMake((b.size.width - 36) / 2, 8, 36, 5)];
    grab.backgroundColor = [UIColor colorWithWhite:1 alpha:0.28]; grab.layer.cornerRadius = 2.5; [cv addSubview:grab];

    self.segment = [[UISegmentedControl alloc] initWithItems:@[@"Scan", @"Enregistrés", @"Régions"]];
    self.segment.frame = CGRectMake(16, 22, b.size.width - 32, 32);
    self.segment.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.segment.selectedSegmentIndex = 0;
    self.segment.selectedSegmentTintColor = ACCENT;
    [self.segment addTarget:self action:@selector(onSegment) forControlEvents:UIControlEventValueChanged];
    [cv addSubview:self.segment];

    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 66, b.size.width, self.sheetH - 66)];
    sc.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sc.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive; sc.showsVerticalScrollIndicator = NO;
    [cv addSubview:sc];
    UIStackView *st = [UIStackView new]; st.axis = UILayoutConstraintAxisVertical; st.spacing = 12; st.translatesAutoresizingMaskIntoConstraints = NO;
    [sc addSubview:st]; self.content = st;
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:sc.contentLayoutGuide.topAnchor constant:14],
        [st.bottomAnchor constraintEqualToAnchor:sc.contentLayoutGuide.bottomAnchor constant:-40],
        [st.leadingAnchor constraintEqualToAnchor:sc.frameLayoutGuide.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:sc.frameLayoutGuide.trailingAnchor constant:-16],
    ]];
}

- (void)openScan { self.tab = 0; [self openSheet]; }
- (void)openSaved { self.tab = 1; [self openSheet]; }
- (void)openRegions { self.tab = 2; [self openSheet]; }
- (void)toggleSheet { if (self.open) [self closeSheet]; else { self.tab = 0; [self openSheet]; } }
- (void)onSegment { self.tab = self.segment.selectedSegmentIndex; [self selectTab]; }

- (void)openSheet {
    self.segment.selectedSegmentIndex = self.tab;
    [self selectTab];
    self.open = YES; gPrismOpen = YES;
    [self.window.rootViewController.view bringSubviewToFront:self.backdrop];
    [self.window.rootViewController.view bringSubviewToFront:self.sheet];
    self.backdrop.hidden = NO;
    CGRect b = self.window.bounds;
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.4 options:0 animations:^{
        self.backdrop.alpha = 1; self.backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
        self.sheet.frame = CGRectMake(0, b.size.height - self.sheetH, b.size.width, self.sheetH);
    } completion:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}
- (void)closeSheet {
    self.open = NO; gPrismOpen = NO; [self.window endEditing:YES];
    [self.timer invalidate]; self.timer = nil;
    CGRect b = self.window.bounds;
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.3 options:0 animations:^{
        self.backdrop.alpha = 0;
        self.sheet.frame = CGRectMake(0, b.size.height, b.size.width, self.sheetH);
    } completion:^(BOOL f) { self.backdrop.hidden = YES; }];
}
- (void)tick { if (self.tab == 1) [self refreshSavedValues]; }

// ── Construction des onglets ────────────────────────────────────────────────
- (void)selectTab {
    for (UIView *v in self.content.arrangedSubviews) [v removeFromSuperview];
    if (self.tab == 0) [self buildScan];
    else if (self.tab == 1) [self buildSaved];
    else [self buildRegions];
}

- (UILabel *)section:(NSString *)t {
    UILabel *l = [UILabel new]; l.text = [t uppercaseString]; l.font = PXText(12, UIFontWeightBold); l.textColor = UIColor.tertiaryLabelColor; return l;
}
- (UIButton *)filled:(NSString *)title color:(UIColor *)c action:(SEL)sel {
    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.title = title; cfg.baseBackgroundColor = c; cfg.baseForegroundColor = UIColor.blackColor;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleLarge; cfg.buttonSize = UIButtonConfigurationSizeMedium;
    UIButton *btn = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return btn;
}
- (UIButton *)tinted:(NSString *)title action:(SEL)sel {
    UIButtonConfiguration *cfg = [UIButtonConfiguration grayButtonConfiguration];
    cfg.title = title; cfg.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    UIButton *btn = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return btn;
}
- (UITextField *)field:(NSString *)ph {
    UITextField *tf = [UITextField new];
    tf.attributedPlaceholder = [[NSAttributedString alloc] initWithString:ph attributes:@{NSForegroundColorAttributeName: UIColor.tertiaryLabelColor}];
    tf.font = PXMono(15, UIFontWeightMedium); tf.textColor = UIColor.labelColor;
    tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation; tf.keyboardAppearance = UIKeyboardAppearanceDark;
    tf.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06]; tf.layer.cornerRadius = 10;
    tf.borderStyle = UITextBorderStyleNone; tf.delegate = self;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)]; tf.leftViewMode = UITextFieldViewModeAlways;
    [tf.heightAnchor constraintEqualToConstant:40].active = YES;
    return tf;
}
- (void)refreshTypeButton {
    UIButtonConfiguration *cfg = [UIButtonConfiguration grayButtonConfiguration];
    cfg.title = self.typeNames[self.currentType];
    cfg.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"];
    cfg.imagePlacement = NSDirectionalRectEdgeTrailing; cfg.imagePadding = 6;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    self.typeButton.configuration = cfg;
    self.typeButton.menu = [self typeMenu];
    self.typeButton.showsMenuAsPrimaryAction = YES;
}
- (UIMenu *)typeMenu {
    NSMutableArray *acts = [NSMutableArray array];
    NSArray *names = [self typeNames];
    __weak typeof(self) ws = self;
    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        UIAction *a = [UIAction actionWithTitle:names[i] image:nil identifier:nil handler:^(__kindof UIAction *ac) {
            ws.currentType = i; [ws refreshTypeButton];
        }];
        a.state = (i == self.currentType) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [acts addObject:a];
    }
    return [UIMenu menuWithTitle:@"Type de valeur" children:acts];
}

- (void)buildScan {
    // Type + recherche
    self.typeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self refreshTypeButton];
    self.searchField = [self field:@"valeur (déc. ou 0x…)"];
    UIStackView *r1 = [[UIStackView alloc] initWithArrangedSubviews:@[self.typeButton, self.searchField, [self filled:@"Scanner" color:ACCENT action:@selector(onScan)]]];
    r1.axis = UILayoutConstraintAxisHorizontal; r1.spacing = 8;
    [self.searchField setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.content addArrangedSubview:r1];

    // Affiner
    [self.content addArrangedSubview:[self section:@"Affiner"]];
    UIStackView *rr = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self tinted:@"=" action:@selector(onRefEq)], [self tinted:@"▲" action:@selector(onRefUp)],
        [self tinted:@"▼" action:@selector(onRefDown)], [self tinted:@"≈" action:@selector(onRefSame)]]];
    rr.axis = UILayoutConstraintAxisHorizontal; rr.spacing = 8; rr.distribution = UIStackViewDistributionFillEqually;
    [self.content addArrangedSubview:rr];

    self.statusLabel = [UILabel new]; self.statusLabel.font = PXMono(12, UIFontWeightMedium); self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.text = @"prêt — saisis une valeur"; [self.content addArrangedSubview:self.statusLabel];

    [self.content addArrangedSubview:[self section:@"Candidats"]];
    self.candBox = [UIStackView new]; self.candBox.axis = UILayoutConstraintAxisVertical; self.candBox.spacing = 6; [self.content addArrangedSubview:self.candBox];
    [self renderCandidates];

    // Édition
    [self.content addArrangedSubview:[self section:@"Éditer"]];
    self.targetLabel = [UILabel new]; self.targetLabel.font = PXMono(13, UIFontWeightSemibold); self.targetLabel.textColor = UIColor.tertiaryLabelColor;
    self.targetLabel.text = self.hasSelected ? [self targetText] : @"touche un candidat pour le cibler";
    [self.content addArrangedSubview:self.targetLabel];
    self.writeField = [self field:@"nouvelle valeur"];
    UIStackView *r3 = [[UIStackView alloc] initWithArrangedSubviews:@[self.writeField, [self filled:@"Écrire" color:FREEZEC action:@selector(onWrite)]]];
    r3.axis = UILayoutConstraintAxisHorizontal; r3.spacing = 8; [self.content addArrangedSubview:r3];
    UIStackView *r4 = [[UIStackView alloc] initWithArrangedSubviews:@[[self tinted:@"Figer" action:@selector(onFreezeSelected)], [self tinted:@"Épingler" action:@selector(onPin)]]];
    r4.axis = UILayoutConstraintAxisHorizontal; r4.spacing = 8; r4.distribution = UIStackViewDistributionFillEqually; [self.content addArrangedSubview:r4];

    // Mode auto : applique la valeur à TOUS les candidats d'un coup.
    [self.content addArrangedSubview:[self section:@"Auto (tous les candidats)"]];
    UIStackView *r5 = [[UIStackView alloc] initWithArrangedSubviews:@[[self filled:@"Éditer tout" color:FREEZEC action:@selector(onWriteAll)], [self tinted:@"Figer tout" action:@selector(onFreezeAll)]]];
    r5.axis = UILayoutConstraintAxisHorizontal; r5.spacing = 8; r5.distribution = UIStackViewDistributionFillEqually; [self.content addArrangedSubview:r5];
}

- (NSString *)targetText {
    NSString *v = PXStr(prism_eng_read((unsigned char)self.currentType, self.selectedAddr));
    return [NSString stringWithFormat:@"0x%010llX  =  %@", self.selectedAddr, v.length ? v : @"?"];
}

- (void)renderCandidates {
    for (UIView *v in self.candBox.arrangedSubviews) [v removeFromSuperview];
    NSInteger shown = MIN((NSInteger)self.sample.count, 60);
    for (NSInteger i = 0; i < shown; i++) {
        unsigned long long addr = [self.sample[i] unsignedLongLongValue];
        NSString *val = PXStr(prism_eng_read((unsigned char)self.currentType, addr));
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem]; row.tag = i;
        [row setTitle:[NSString stringWithFormat:@"  0x%010llX      %@", addr, val] forState:UIControlStateNormal];
        row.titleLabel.font = PXMono(13, UIFontWeightMedium); [row setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        row.backgroundColor = (self.hasSelected && self.selectedAddr == addr) ? [ACCENT colorWithAlphaComponent:0.22] : [UIColor colorWithWhite:1 alpha:0.05];
        row.layer.cornerRadius = 9; [row.heightAnchor constraintEqualToConstant:36].active = YES;
        [row addTarget:self action:@selector(onCandidate:) forControlEvents:UIControlEventTouchUpInside];
        [self.candBox addArrangedSubview:row];
    }
    if (self.sample.count == 0) {
        UILabel *e = [UILabel new]; e.text = @"—"; e.font = PXMono(13, UIFontWeightRegular); e.textColor = UIColor.tertiaryLabelColor; [self.candBox addArrangedSubview:e];
    }
}
- (void)onCandidate:(UIButton *)b {
    if (b.tag < 0 || b.tag >= (NSInteger)self.sample.count) return;
    self.selectedAddr = [self.sample[b.tag] unsignedLongLongValue]; self.hasSelected = YES;
    self.targetLabel.textColor = UIColor.labelColor; self.targetLabel.text = [self targetText];
    [self renderCandidates];
}

- (unsigned char)ty { return (unsigned char)self.currentType; }
- (int)parseInt:(UITextField *)f { return [f.text intValue]; }

- (void)applyScan:(NSDictionary *)d verb:(NSString *)verb {
    if (!d) { self.statusLabel.textColor = BADC; self.statusLabel.text = @"valeur invalide"; return; }
    NSInteger count = [d[@"count"] integerValue]; self.sample = d[@"sample"] ?: @[];
    self.statusLabel.textColor = count > 0 ? ACCENT : UIColor.secondaryLabelColor;
    self.statusLabel.text = [NSString stringWithFormat:@"%@ — %ld résultat%@", verb, (long)count, count > 1 ? @"s" : @""];
    [self renderCandidates];
}
- (void)onScan { [self.window endEditing:YES]; [self applyScan:PXObj(prism_eng_scan([self ty], self.searchField.text.UTF8String ?: "")) verb:@"scan"]; }
- (void)refine:(unsigned char)op { [self applyScan:PXObj(prism_eng_refine([self ty], op, self.searchField.text.UTF8String ?: "")) verb:@"affiné"]; }
- (void)onRefEq { [self refine:0]; }
- (void)onRefUp { [self refine:1]; }
- (void)onRefDown { [self refine:2]; }
- (void)onRefSame { [self refine:3]; }

- (void)onWrite {
    if (!self.hasSelected) { self.targetLabel.textColor = BADC; self.targetLabel.text = @"choisis un candidat d'abord"; return; }
    int rc = prism_eng_write([self ty], self.selectedAddr, self.writeField.text.UTF8String ?: "");
    self.targetLabel.textColor = rc == 0 ? OKC : BADC; self.targetLabel.text = rc == 0 ? [self targetText] : @"écriture refusée";
    [self pulseBar]; [self renderCandidates];
}
- (void)onFreezeSelected {
    if (!self.hasSelected) return;
    if (prism_eng_freeze_has(self.selectedAddr)) { prism_eng_freeze_remove(self.selectedAddr); }
    else { prism_eng_freeze_add([self ty], self.selectedAddr, (self.writeField.text.length ? self.writeField.text : PXStr(prism_eng_read([self ty], self.selectedAddr))).UTF8String ?: ""); }
    [self pulseBar];
}
- (void)onPin {
    if (!self.hasSelected) return;
    for (NSDictionary *d in self.saved) if ([d[@"addr"] unsignedLongLongValue] == self.selectedAddr) return;
    [self.saved addObject:@{@"ty": @(self.currentType), @"addr": @(self.selectedAddr)}];
    self.targetLabel.textColor = OKC; self.targetLabel.text = [NSString stringWithFormat:@"épinglé : 0x%010llX", self.selectedAddr];
}
- (void)onWriteAll {
    int n = prism_eng_write_all([self ty], self.writeField.text.UTF8String ?: "");
    self.statusLabel.textColor = n >= 0 ? OKC : BADC;
    self.statusLabel.text = n >= 0 ? [NSString stringWithFormat:@"écrit sur %d adresses", n] : @"valeur invalide";
    [self pulseBar]; [self renderCandidates];
}
- (void)onFreezeAll {
    int n = prism_eng_freeze_all([self ty], self.writeField.text.UTF8String ?: "");
    self.statusLabel.textColor = n >= 0 ? FREEZEC : BADC;
    self.statusLabel.text = n >= 0 ? [NSString stringWithFormat:@"%d adresses figées", n] : @"valeur invalide";
    [self pulseBar];
}

// ── Onglet Enregistrés ──────────────────────────────────────────────────────
- (void)buildSaved {
    self.savedValueLabels = [NSMutableArray array];
    if (self.saved.count == 0) {
        UILabel *e = [UILabel new]; e.numberOfLines = 0; e.font = PXText(14, UIFontWeightRegular); e.textColor = UIColor.secondaryLabelColor;
        e.text = @"Aucune adresse enregistrée.\nDepuis Scan, cible un candidat puis « Épingler ».";
        [self.content addArrangedSubview:e]; return;
    }
    for (NSInteger i = 0; i < (NSInteger)self.saved.count; i++) {
        NSDictionary *entry = self.saved[i];
        unsigned char ty = (unsigned char)[entry[@"ty"] integerValue];
        unsigned long long addr = [entry[@"addr"] unsignedLongLongValue];

        UIView *rowv = [[UIView alloc] init]; rowv.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05]; rowv.layer.cornerRadius = 10;
        UILabel *tychip = [UILabel new]; tychip.text = self.typeNames[[entry[@"ty"] integerValue]]; tychip.font = PXMono(11, UIFontWeightBold); tychip.textColor = ACCENT;
        UILabel *al = [UILabel new]; al.text = [NSString stringWithFormat:@"0x%010llX", addr]; al.font = PXMono(13, UIFontWeightSemibold); al.textColor = UIColor.labelColor;
        UILabel *vl = [UILabel new]; vl.font = PXMono(13, UIFontWeightMedium); vl.textColor = OKC; vl.text = PXStr(prism_eng_read(ty, addr));
        [self.savedValueLabels addObject:vl];
        UISwitch *fz = [UISwitch new]; fz.onTintColor = FREEZEC; fz.on = prism_eng_freeze_has(addr) != 0; fz.tag = i;
        [fz addTarget:self action:@selector(onSavedFreeze:) forControlEvents:UIControlEventValueChanged];
        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem]; del.tag = i; del.tintColor = UIColor.tertiaryLabelColor;
        [del setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        [del addTarget:self action:@selector(onSavedDelete:) forControlEvents:UIControlEventTouchUpInside];

        UIStackView *left = [[UIStackView alloc] initWithArrangedSubviews:@[al, vl]]; left.axis = UILayoutConstraintAxisVertical; left.spacing = 1;
        UIStackView *hs = [[UIStackView alloc] initWithArrangedSubviews:@[tychip, left, fz, del]];
        hs.axis = UILayoutConstraintAxisHorizontal; hs.spacing = 10; hs.alignment = UIStackViewAlignmentCenter;
        hs.translatesAutoresizingMaskIntoConstraints = NO; hs.layoutMarginsRelativeArrangement = YES; hs.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(8, 12, 8, 10);
        [tychip.widthAnchor constraintEqualToConstant:34].active = YES;
        [left setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [rowv addSubview:hs];
        [NSLayoutConstraint activateConstraints:@[[hs.topAnchor constraintEqualToAnchor:rowv.topAnchor], [hs.bottomAnchor constraintEqualToAnchor:rowv.bottomAnchor], [hs.leadingAnchor constraintEqualToAnchor:rowv.leadingAnchor], [hs.trailingAnchor constraintEqualToAnchor:rowv.trailingAnchor]]];

        UITapGestureRecognizer *tp = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onSavedTap:)];
        rowv.tag = i; [rowv addGestureRecognizer:tp];
        [self.content addArrangedSubview:rowv];
    }
    [self.content addArrangedSubview:[self filled:@"Tout dégeler" color:ACCENT action:@selector(onUnfreezeAll)]];
}
- (void)refreshSavedValues {
    for (NSInteger i = 0; i < (NSInteger)self.savedValueLabels.count && i < (NSInteger)self.saved.count; i++) {
        NSDictionary *e = self.saved[i];
        self.savedValueLabels[i].text = PXStr(prism_eng_read((unsigned char)[e[@"ty"] integerValue], [e[@"addr"] unsignedLongLongValue]));
    }
}
- (void)onSavedFreeze:(UISwitch *)sw {
    if (sw.tag >= (NSInteger)self.saved.count) return;
    NSDictionary *e = self.saved[sw.tag]; unsigned long long addr = [e[@"addr"] unsignedLongLongValue];
    if (sw.on) prism_eng_freeze_add((unsigned char)[e[@"ty"] integerValue], addr, PXStr(prism_eng_read((unsigned char)[e[@"ty"] integerValue], addr)).UTF8String ?: "");
    else prism_eng_freeze_remove(addr);
    [self pulseBar];
}
- (void)onSavedDelete:(UIButton *)b {
    if (b.tag >= (NSInteger)self.saved.count) return;
    prism_eng_freeze_remove([self.saved[b.tag][@"addr"] unsignedLongLongValue]);
    [self.saved removeObjectAtIndex:b.tag]; [self selectTab];
}
- (void)onSavedTap:(UITapGestureRecognizer *)g {
    NSInteger i = g.view.tag; if (i >= (NSInteger)self.saved.count) return;
    NSDictionary *e = self.saved[i]; unsigned char ty = (unsigned char)[e[@"ty"] integerValue]; unsigned long long addr = [e[@"addr"] unsignedLongLongValue];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"0x%010llX", addr] message:@"Nouvelle valeur" preferredStyle:UIAlertControllerStyleAlert];
    ac.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation; tf.text = PXStr(prism_eng_read(ty, addr)); }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Écrire" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        prism_eng_write(ty, addr, ac.textFields.firstObject.text.UTF8String ?: ""); [self pulseBar];
    }]];
    [self.window.rootViewController presentViewController:ac animated:YES completion:nil];
}
- (void)onUnfreezeAll { prism_eng_freeze_clear(); [self pulseBar]; [self selectTab]; }

// ── Onglet Régions ──────────────────────────────────────────────────────────
- (void)buildRegions {
    [self.content addArrangedSubview:[self filled:@"Charger les régions" color:ACCENT action:@selector(onRegionsLoad)]];
    UIStackView *box = [UIStackView new]; box.axis = UILayoutConstraintAxisVertical; box.spacing = 5; box.tag = 909; [self.content addArrangedSubview:box];
}
- (void)onRegionsLoad {
    UIStackView *box = nil; for (UIView *v in self.content.arrangedSubviews) if (v.tag == 909 && [v isKindOfClass:[UIStackView class]]) box = (UIStackView *)v;
    if (!box) return; for (UIView *v in box.arrangedSubviews) [v removeFromSuperview];
    NSArray *regs = PXArr(prism_eng_regions()); NSInteger shown = MIN((NSInteger)regs.count, 80);
    for (NSInteger i = 0; i < shown; i++) {
        NSDictionary *r = regs[i]; unsigned long long addr = [r[@"addr"] unsignedLongLongValue]; unsigned long long size = [r[@"size"] unsignedLongLongValue]; int prot = [r[@"prot"] intValue];
        NSString *ps = [NSString stringWithFormat:@"%@%@%@", (prot & 1) ? @"r" : @"-", (prot & 2) ? @"w" : @"-", (prot & 4) ? @"x" : @"-"];
        UILabel *l = [UILabel new]; l.font = PXMono(12, UIFontWeightMedium); l.textColor = UIColor.secondaryLabelColor;
        l.text = [NSString stringWithFormat:@"0x%010llX   %@   %@", addr, ps, [self human:size]]; [box addArrangedSubview:l];
    }
    UILabel *tot = [UILabel new]; tot.font = PXMono(12, UIFontWeightRegular); tot.textColor = UIColor.tertiaryLabelColor; tot.text = [NSString stringWithFormat:@"%lu régions", (unsigned long)regs.count]; [box addArrangedSubview:tot];
}
- (NSString *)human:(unsigned long long)n {
    const char *u[] = {"o", "Ko", "Mo", "Go"}; double v = (double)n; int i = 0;
    while (v >= 1024 && i < 3) { v /= 1024; i++; }
    return [NSString stringWithFormat:(v < 10 && i > 0) ? @"%.1f%s" : @"%.0f%s", v, u[i]];
}

- (void)pulseBar {
    BOOL frozen = prism_eng_freeze_count() > 0;
    self.bar.layer.borderColor = [(frozen ? FREEZEC : [UIColor colorWithWhite:1 alpha:0.12]) colorWithAlphaComponent:frozen ? 0.9 : 0.12].CGColor;
    UIView *v = self.bar;
    [UIView animateWithDuration:0.14 animations:^{ v.transform = CGAffineTransformMakeScale(1.12, 1.12); } completion:^(BOOL f) {
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.6 options:0 animations:^{ v.transform = CGAffineTransformIdentity; } completion:nil];
    }];
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
@end

// ── Point d'entrée (ctor Rust) ──────────────────────────────────────────────
void prism_overlay_bootstrap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{ [[PrismOverlayController shared] tryInstall]; });
    });
}
