// Tweak de test « autonome » pour valider l'injection (palier 1).
//
// Aucune dépendance à Substrate/ElleKit : uniquement UIKit + Foundation, qui
// sont présents dans toute app iOS. Au lancement, il affiche une alerte
// « Tweak injecté ✅ » — preuve visuelle que le dylib a bien été chargé.
//
// Le constructeur s'exécute au chargement du dylib (donc avant l'UI) ; on
// attend UIApplicationDidBecomeActiveNotification pour présenter l'alerte quand
// une fenêtre existe.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

__attribute__((constructor))
static void pxhello_init(void) {
    NSLog(@"[PXHello] dylib chargé — injection réussie");

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        static BOOL shown = NO;
        if (shown) return;
        shown = YES;

        // Trouve une fenêtre clé, avec ou sans UIScene.
        UIWindow *window = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
        if (window == nil) {
            window = UIApplication.sharedApplication.windows.firstObject;
        }

        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Parallax"
                             message:@"Tweak injecté ✅"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [window.rootViewController presentViewController:alert animated:YES completion:nil];
    }];
}
