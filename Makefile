SWIFTC        = /usr/bin/swiftc
BIN           = Moose
SRC           = Moose.swift
PLIST_NAME    = com.studiowebux.moose.plist
INSTALL_BIN   = $(HOME)/.local/bin/$(BIN)
LAUNCH_AGENTS = $(HOME)/Library/LaunchAgents

.PHONY: all install restart uninstall run clean

all: $(BIN)

$(BIN): $(SRC)
	$(SWIFTC) $(SRC) -o $(BIN) -framework IOKit -framework Cocoa


install: $(BIN)
	mkdir -p $(HOME)/.local/bin $(LAUNCH_AGENTS)
	cp $(BIN) $(INSTALL_BIN)
	chmod +x $(INSTALL_BIN)
	sed "s|MOOSE_BIN|$(INSTALL_BIN)|" $(PLIST_NAME) > $(LAUNCH_AGENTS)/$(PLIST_NAME)
	launchctl load $(LAUNCH_AGENTS)/$(PLIST_NAME)
	@echo "Moose installed."
	@echo "1. Add ~/.local/bin/Moose in System Settings > Privacy & Security > Accessibility"
	@echo "2. Toggle it ON, then run: make restart"
	open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

restart:
	launchctl unload $(LAUNCH_AGENTS)/$(PLIST_NAME)
	launchctl load $(LAUNCH_AGENTS)/$(PLIST_NAME)

uninstall:
	-launchctl unload $(LAUNCH_AGENTS)/$(PLIST_NAME)
	-pkill $(BIN)
	-rm -f $(LAUNCH_AGENTS)/$(PLIST_NAME)
	-rm -f $(INSTALL_BIN)
	@echo "Uninstalled."

run: $(BIN)
	./$(BIN)

clean:
	rm -f $(BIN) $(BIN).zip
