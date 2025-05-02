# Pomodoro Timer Enhancement TODO List

## Current Issues

- The enhanced notification system has critical bugs that prevent the timer from advancing past 27 minutes
- The current implementation uses methods that don't exist in Hammerspoon's API
- Error handling is insufficient, allowing errors to propagate and disrupt core functionality

## Immediate Fixes (Currently Being Implemented)

- [x] Create a reliable Picture-in-Picture notification that works on all monitors
- [x] Fix the timer stalling issue at 27 minutes
- [x] Implement proper error isolation so notification failures don't break the timer

## Future Enhancements

### Error Handling

- [ ] Add more granular error handling for different types of failures
- [ ] Implement logging for notification lifecycle events
- [ ] Create fallback behavior when primary notification methods fail

### User Experience

- [ ] Improve visual design of the PiP notification
- [ ] Add configuration options for notification appearance
- [ ] Implement different notification levels based on how overdue the break is
- [ ] Consider adding keyboard shortcuts to dismiss notifications

### Code Structure 

- [ ] Centralize cleanup logic into a single function
- [ ] Create a dedicated notification state management system
- [ ] Separate UI rendering from state management logic
- [ ] Write unit tests for core notification functionality

### Performance

- [ ] Optimize canvas rendering for better performance
- [ ] Minimize resource usage for long-running notifications
- [ ] Ensure proper cleanup of all resources to prevent memory leaks

### Additional Features

- [ ] Add an option to postpone a break for a few minutes
- [ ] Create a break suggestions system (stretching, eye exercises, etc.)
- [ ] Track statistics about work sessions and breaks
- [ ] Allow customizing notification sound