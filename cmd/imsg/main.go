// Command imsg is a CLI for interacting with macOS Messages.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/steipete/imsg/internal/db"
	"github.com/steipete/imsg/internal/send"
	"github.com/steipete/imsg/internal/watch"
)

var (
	dbPath  string
	version = "dev"
)

func main() {
	root := &cobra.Command{
		Use:   "imsg",
		Short: "Send and read iMessage / SMS from the terminal",
		Long: `Examples:
  imsg chats --limit 5
  imsg history --chat-id 1 --limit 10 --attachments
  imsg history --chat-id 1 --start 2025-01-01T00:00:00Z --json
  imsg watch --chat-id 1 --attachments --interval 2s
  imsg send --to "+14155551212" --text "hi" --file ~/Desktop/pic.jpg --service imessage
`,
		Version: version,
	}

	root.PersistentFlags().StringVar(&dbPath, "db", db.DefaultPath(), "Path to chat.db (defaults to ~/Library/Messages/chat.db)")
	root.PersistentFlags().BoolP("version", "V", false, "Show version")

	root.SetVersionTemplate("{{.Version}}\n")

	root.AddCommand(newChatsCmd())
	root.AddCommand(newHistoryCmd())
	root.AddCommand(newWatchCmd())
	root.AddCommand(newSendCmd())

	if err := root.Execute(); err != nil {
		log.Fatal(err)
	}
}

func newChatsCmd() *cobra.Command {
	var limit int
	var jsonOut bool
	cmd := &cobra.Command{
		Use:   "chats",
		Short: "List recent conversations",
		RunE: func(cmd *cobra.Command, args []string) error {
			_ = args
			ctx := cmd.Context()
			store, err := db.Open(ctx, dbPath)
			if err != nil {
				return err
			}
			defer func() { _ = store.Close() }()

			chats, err := db.ListChats(ctx, store, limit)
			if err != nil {
				return err
			}
			if jsonOut {
				enc := json.NewEncoder(os.Stdout)
				for _, c := range chats {
					if err := enc.Encode(map[string]any{
						"id":              c.ID,
						"name":            c.Name,
						"identifier":      c.Identifier,
						"service":         c.Service,
						"last_message_at": c.LastMessageAt.Format(time.RFC3339),
					}); err != nil {
						return err
					}
				}
				return nil
			}
			for _, c := range chats {
				fmt.Printf("[%d] %s (%s) last=%s\n", c.ID, c.Name, c.Identifier, c.LastMessageAt.Format(time.RFC3339))
			}
			return nil
		},
	}
	cmd.Flags().IntVar(&limit, "limit", 20, "Number of chats to list")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "emit JSON objects instead of plain text")
	return cmd
}

func newHistoryCmd() *cobra.Command {
	var (
		chatID          int64
		limit           int
		showAttachments bool
		participants    []string
		startISO        string
		endISO          string
		jsonOut         bool
	)
	cmd := &cobra.Command{
		Use:   "history",
		Short: "Show recent messages for a chat",
		RunE: func(cmd *cobra.Command, args []string) error {
			_ = args
			if chatID == 0 {
				return fmt.Errorf("--chat-id is required")
			}
			ctx := cmd.Context()
			store, err := db.Open(ctx, dbPath)
			if err != nil {
				return err
			}
			defer func() { _ = store.Close() }()

			messages, err := db.MessagesByChat(ctx, store, chatID, limit)
			if err != nil {
				return err
			}
			filtered := filterMessages(messages, participants, startISO, endISO)

			if jsonOut {
				return printJSON(filtered, func(m db.Message, metas []db.AttachmentMeta) map[string]any {
					return map[string]any{
						"id":          m.RowID,
						"chat_id":     m.ChatID,
						"sender":      m.Sender,
						"is_from_me":  m.IsFromMe,
						"text":        m.Text,
						"created_at":  m.Date.Format(time.RFC3339),
						"attachments": metas,
					}
				})
			}

			for _, m := range filtered {
				direction := "recv"
				if m.IsFromMe {
					direction = "sent"
				}
				fmt.Printf("%s [%s] %s: %s\n", m.Date.Format(time.RFC3339), direction, m.Sender, m.Text)
				if m.Attachments > 0 {
					if showAttachments {
						metas, err := db.AttachmentsByMessage(ctx, store, m.RowID)
						if err != nil {
							return err
						}
						for _, meta := range metas {
							fmt.Printf("  attachment: name=%s mime=%s missing=%t path=%s\n", displayName(meta), meta.MimeType, meta.Missing, meta.OriginalPath)
						}
					} else {
						fmt.Printf("  (%d attachment%c)\n", m.Attachments, plural(m.Attachments))
					}
				}
			}
			return nil
		},
	}
	cmd.Flags().Int64Var(&chatID, "chat-id", 0, "chat rowid from 'imsg chats'")
	cmd.Flags().IntVar(&limit, "limit", 50, "Number of messages to show")
	cmd.Flags().BoolVar(&showAttachments, "attachments", false, "include attachment metadata")
	cmd.Flags().StringSliceVar(&participants, "participants", nil, "filter by participant handles (E.164 or email)")
	cmd.Flags().StringVar(&startISO, "start", "", "ISO8601 start (inclusive), e.g. 2025-01-01T00:00:00Z")
	cmd.Flags().StringVar(&endISO, "end", "", "ISO8601 end (exclusive)")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "emit JSON objects instead of plain text")
	return cmd
}

func newWatchCmd() *cobra.Command {
	var (
		chatID          int64
		interval        time.Duration
		since           int64
		showAttachments bool
		participants    []string
		startISO        string
		endISO          string
		jsonOut         bool
	)
	cmd := &cobra.Command{
		Use:   "watch",
		Short: "Stream incoming messages",
		RunE: func(cmd *cobra.Command, args []string) error {
			_ = args
			ctx, cancel := context.WithCancel(cmd.Context())
			defer cancel()

			store, err := db.Open(ctx, dbPath)
			if err != nil {
				return err
			}
			defer func() { _ = store.Close() }()

			sig := make(chan os.Signal, 1)
			signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
			go func() {
				<-sig
				cancel()
			}()

			startRowID := since
			if startRowID == 0 {
				startRowID, err = db.MaxRowID(ctx, store)
				if err != nil {
					return err
				}
			}

			return watch.Run(ctx, store, chatID, startRowID, interval, func(msg db.Message) {
				direction := "recv"
				if msg.IsFromMe {
					direction = "sent"
				}
				if !passesFilters(msg, participants, startISO, endISO) {
					return
				}
				if jsonOut {
					metas, _ := db.AttachmentsByMessage(ctx, store, msg.RowID)
					entry := map[string]any{
						"id":          msg.RowID,
						"chat_id":     msg.ChatID,
						"sender":      msg.Sender,
						"is_from_me":  msg.IsFromMe,
						"text":        msg.Text,
						"created_at":  msg.Date.Format(time.RFC3339),
						"attachments": metas,
					}
					printJSONSingle(entry)
					return
				}
				fmt.Printf("%s [%s] %s: %s\n", msg.Date.Format(time.RFC3339), direction, msg.Sender, msg.Text)
				if msg.Attachments > 0 {
					if showAttachments {
						metas, err := db.AttachmentsByMessage(ctx, store, msg.RowID)
						if err == nil {
							for _, meta := range metas {
								fmt.Printf("  attachment: name=%s mime=%s missing=%t path=%s\n", displayName(meta), meta.MimeType, meta.Missing, meta.OriginalPath)
							}
						}
					} else {
						fmt.Printf("  (%d attachment%c)\n", msg.Attachments, plural(msg.Attachments))
					}
				}
			})
		},
	}
	cmd.Flags().Int64Var(&chatID, "chat-id", 0, "limit to chat rowid")
	cmd.Flags().DurationVar(&interval, "interval", 2*time.Second, "polling interval")
	cmd.Flags().Int64Var(&since, "since-rowid", 0, "start watching after this rowid (defaults to current max)")
	cmd.Flags().BoolVar(&showAttachments, "attachments", false, "include attachment metadata")
	cmd.Flags().StringSliceVar(&participants, "participants", nil, "filter by participant handles (E.164 or email)")
	cmd.Flags().StringVar(&startISO, "start", "", "ISO8601 start (inclusive), e.g. 2025-01-01T00:00:00Z")
	cmd.Flags().StringVar(&endISO, "end", "", "ISO8601 end (exclusive)")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "emit JSON objects instead of plain text")
	return cmd
}

func newSendCmd() *cobra.Command {
	var opts send.Options
	cmd := &cobra.Command{
		Use:   "send",
		Short: "Send a message (text and/or attachment)",
		RunE: func(cmd *cobra.Command, args []string) error {
			_ = args
			if opts.Recipient == "" {
				return fmt.Errorf("--to is required")
			}
			if opts.Text == "" && opts.AttachmentPath == "" {
				return fmt.Errorf("set --text and/or --file")
			}
			ctx := cmd.Context()
			if err := send.Send(ctx, opts); err != nil {
				return err
			}
			fmt.Println("sent")
			return nil
		},
	}
	cmd.Flags().StringVar(&opts.Recipient, "to", "", "phone number or email")
	cmd.Flags().StringVar(&opts.Text, "text", "", "message body")
	cmd.Flags().StringVar(&opts.AttachmentPath, "file", "", "path to attachment")
	cmd.Flags().StringVar((*string)(&opts.Service), "service", string(send.ServiceAuto), "service to use: imessage|sms|auto")
	cmd.Flags().StringVar(&opts.Region, "region", "US", "default region for phone normalization (ISO 3166-1 alpha-2)")
	return cmd
}

func plural(n int) rune {
	if n == 1 {
		return ' '
	}
	return 's'
}

func parseISO(ts string) (time.Time, bool) {
	if ts == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339, ts); err == nil {
		return t, true
	}
	return time.Time{}, false
}

func filterMessages(msgs []db.Message, participants []string, startISO, endISO string) []db.Message {
	start, hasStart := parseISO(startISO)
	end, hasEnd := parseISO(endISO)
	filters := func(m db.Message) bool {
		if hasStart && m.Date.Before(start) {
			return false
		}
		if hasEnd && !m.Date.Before(end) {
			return false
		}
		if len(participants) > 0 {
			match := false
			for _, p := range participants {
				if strings.EqualFold(m.Sender, p) {
					match = true
					break
				}
			}
			if !match {
				return false
			}
		}
		return true
	}
	out := make([]db.Message, 0, len(msgs))
	for _, m := range msgs {
		if filters(m) {
			out = append(out, m)
		}
	}
	return out
}

func passesFilters(m db.Message, participants []string, startISO, endISO string) bool {
	return len(filterMessages([]db.Message{m}, participants, startISO, endISO)) > 0
}

func printJSON(msgs []db.Message, fn func(db.Message, []db.AttachmentMeta) map[string]any) error {
	enc := json.NewEncoder(os.Stdout)
	for _, m := range msgs {
		metas, _ := db.AttachmentsByMessage(context.Background(), mustOpenDB(), m.RowID)
		if err := enc.Encode(fn(m, metas)); err != nil {
			return err
		}
	}
	return nil
}

func printJSONSingle(entry map[string]any) {
	enc := json.NewEncoder(os.Stdout)
	_ = enc.Encode(entry)
}

// mustOpenDB reuses dbPath to fetch attachments when printing JSON inside watchers.
func mustOpenDB() *sql.DB {
	ctx := context.Background()
	store, _ := db.Open(ctx, dbPath)
	return store
}

func displayName(meta db.AttachmentMeta) string {
	if meta.TransferName != "" {
		return meta.TransferName
	}
	if meta.Filename != "" {
		return meta.Filename
	}
	return "(unknown)"
}
