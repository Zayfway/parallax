#ifndef PRISM_OVERLAY_H
#define PRISM_OVERLAY_H
#include <stdint.h>

// Point d'entrée appelé par le constructeur Rust (installe l'overlay in-app).
void prism_overlay_bootstrap(void);

// ── Moteur mémoire (implémenté en Rust, engine.rs) ──────────────────────────
// Les chaînes rendues sont possédées par l'appelant : libérer via prism_eng_free.
char *prism_eng_regions(void);              // JSON [{addr,size,prot,tag}]
char *prism_eng_scan_i32(int value);        // JSON {count,sample}
char *prism_eng_refine(unsigned char op, int value); // op = 0 EQ,1 UP,2 DOWN,3 SAME
int   prism_eng_read_i32(unsigned long long addr, int *out);
int   prism_eng_write_i32(unsigned long long addr, int value);
void  prism_eng_free(char *p);
void  prism_eng_freeze_add(unsigned long long addr, int value);
void  prism_eng_freeze_remove(unsigned long long addr);
void  prism_eng_freeze_clear(void);
int   prism_eng_freeze_count(void);

#endif /* PRISM_OVERLAY_H */
