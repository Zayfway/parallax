# Site de Parallax

HTML et CSS servis tels quels, sans build. Publié sur GitHub Pages par
`.github/workflows/deploy-web.yml` à chaque poussée touchant `web/`.

## Jetons

Les couleurs, rayons et courbes sont **copiés** de `ios-app/DesignSystem.swift`.
Un site qui ressemble vaguement à l'app est pire qu'un site qui ne lui ressemble
pas : l'écart se remarque. Si un jeton change côté app, il change ici.

Les deux règles du système tiennent aussi sur le web :

- l'ambre (`--signal`) signifie « position simulée », jamais « bouton joli ».
  Sur ce site elle n'apparaît que sur le module GPS et l'écho du titre ;
- mono pour ce que la machine affirme, rounded pour ce qui s'adresse à l'humain.

## Ce qui n'est pas encore là

L'installation directe depuis la page. Elle demandera un profil DNS et des
certificats de signature, et sera servie sous plusieurs certificats pour qu'il
reste un chemin ouvert si l'un est révoqué. La section existe déjà et annonce
l'attente plutôt que de la masquer.

## Activer Pages

Une seule fois : dépôt › Settings › Pages › Source = **GitHub Actions**.
