# Starship prompt for every user of this image, system-wide.
#
# fish reads /etc/fish/conf.d/*.fish before ~/.config/fish/config.fish, so a
# user's own configuration still gets the last word. The drop-in lives in the
# image rather than in ~/.config/fish because $HOME is routinely a volume here:
# the README quick start bind-mounts one over /home/coder, which would hide a
# per-user file.
#
# Guarded so a stripped-down rebuild without starship still starts a usable
# shell instead of failing every prompt.
if command -q starship
    starship init fish | source
end
