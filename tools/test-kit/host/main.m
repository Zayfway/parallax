// App hôte minimale, pour tester l'injection dans quelque chose de propre et
// de connu. Cycle de vie « legacy » (AppDelegate + UIWindow, sans UIScene) :
// c'est le plus simple et il suffit largement ici.

#import <UIKit/UIKit.h>

@interface PXAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation PXAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.systemIndigoColor;

    UILabel *label = [[UILabel alloc] initWithFrame:root.view.bounds];
    label.text = @"Parallax — app hôte de test";
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:label];

    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(PXAppDelegate.class));
    }
}
