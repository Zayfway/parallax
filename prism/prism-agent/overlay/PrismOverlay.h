#ifndef PRISM_OVERLAY_H
#define PRISM_OVERLAY_H
#include <stdint.h>

// Point d'entrée appelé par le constructeur Rust (installe l'overlay in-app).
void prism_overlay_bootstrap(void);

// ── Moteur mémoire typé (implémenté en Rust, engine.rs) ─────────────────────
// ty : 0 i8,1 i16,2 i32,3 i64,4 u8,5 u16,6 u32,7 u64,8 f32,9 f64.
// Les chaînes rendues sont possédées par l'appelant : libérer via prism_eng_free.
char *prism_eng_regions(void);                                         // JSON [{addr,size,prot,tag}]
char *prism_eng_scan(unsigned char ty, const char *value);            // JSON {count,sample}
char *prism_eng_fuzzy_start(unsigned char ty);                        // recherche floue (valeur inconnue)
char *prism_eng_refine(unsigned char ty, unsigned char op, const char *value); // op 0 EQ,1 UP,2 DOWN,3 SAME,4 CHANGED
char *prism_eng_read(unsigned char ty, unsigned long long addr);      // valeur formatée (ou "")
int   prism_eng_write(unsigned char ty, unsigned long long addr, const char *value);
int   prism_eng_write_all(unsigned char ty, const char *value);   // mode auto
int   prism_eng_freeze_all(unsigned char ty, const char *value);  // mode auto
void  prism_eng_free(char *p);
void  prism_eng_freeze_add(unsigned char ty, unsigned long long addr, const char *value);
void  prism_eng_freeze_remove(unsigned long long addr);
void  prism_eng_freeze_clear(void);
int   prism_eng_freeze_has(unsigned long long addr);
int   prism_eng_freeze_count(void);

#endif /* PRISM_OVERLAY_H */
