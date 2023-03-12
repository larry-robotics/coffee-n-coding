#!/bin/bash

echo Update zola-theme-terminimal

git subtree pull --prefix blog/themes/zola-theme-terminimal git@github.com:larry-robotics/zola-theme-terminimal.git master --squash
