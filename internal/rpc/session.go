package rpc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
)

type Call struct {
	ID     string
	Method string
	Params json.RawMessage
}

type Emit func(event string, revision uint64, data any) error

type Handler interface {
	Handle(context.Context, Call, Emit) (any, error)
}

type HandlerFunc func(context.Context, Call, Emit) (any, error)

func (function HandlerFunc) Handle(ctx context.Context, call Call, emit Emit) (any, error) {
	return function(ctx, call, emit)
}

type Session struct {
	Handler      Handler
	Capabilities []string
	Buffer       int
}

func (session Session) Serve(ctx context.Context, input io.Reader, output io.Writer) error {
	if session.Handler == nil {
		return errors.New("RPC handler is required")
	}
	ctx, stop := context.WithCancel(ctx)
	defer stop()
	codec := NewCodec(input, output)
	buffer := session.Buffer
	if buffer <= 0 {
		buffer = 64
	}
	outgoing := make(chan Response, buffer)
	writerDone := make(chan error, 1)
	go func() {
		for response := range outgoing {
			if err := codec.Write(response); err != nil {
				writerDone <- err
				stop()
				return
			}
		}
		writerDone <- nil
	}()

	var negotiated atomic.Bool
	var sequence atomic.Uint64
	var workers sync.WaitGroup
	operations := make(map[string]context.CancelCauseFunc)
	var operationsMu sync.Mutex
	enqueue := func(response Response) error {
		select {
		case outgoing <- response:
			return nil
		case <-ctx.Done():
			return context.Cause(ctx)
		default:
			stop()
			return errors.New("RPC client exceeded bounded backpressure buffer")
		}
	}

	readErr := error(nil)
	for ctx.Err() == nil {
		request, err := codec.ReadRequest()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				readErr = err
			}
			break
		}
		if err := validateRequest(request); err != nil {
			_ = enqueue(Response{Version: ProtocolVersion, Type: "response", ID: request.ID, Error: asFault(err)})
			continue
		}
		if request.Type == "cancel" {
			operationsMu.Lock()
			cancel := operations[request.OperationID]
			operationsMu.Unlock()
			if cancel == nil {
				_ = enqueue(Response{Version: ProtocolVersion, Type: "response", ID: request.ID,
					Error: &Error{Code: "operation_not_found", Message: "operation is not active"}})
			} else {
				cancel(contextCanceled)
				_ = enqueue(Response{Version: ProtocolVersion, Type: "response", ID: request.ID,
					Result: map[string]any{"cancelled": request.OperationID}})
			}
			continue
		}
		if request.Method == "rpc.negotiate" {
			negotiated.Store(true)
			_ = enqueue(Response{Version: ProtocolVersion, Type: "response", ID: request.ID, Result: map[string]any{
				"version": ProtocolVersion, "capabilities": session.Capabilities,
			}})
			continue
		}
		if !negotiated.Load() {
			_ = enqueue(Response{Version: ProtocolVersion, Type: "response", ID: request.ID,
				Error: &Error{Code: "negotiation_required", Message: "rpc.negotiate must be called first"}})
			continue
		}
		operationContext, cancel := context.WithCancelCause(ctx)
		operationsMu.Lock()
		if _, duplicate := operations[request.ID]; duplicate {
			operationsMu.Unlock()
			cancel(nil)
			_ = enqueue(Response{Version: ProtocolVersion, Type: "response", ID: request.ID,
				Error: &Error{Code: "duplicate_operation", Message: "request ID is already active"}})
			continue
		}
		operations[request.ID] = cancel
		operationsMu.Unlock()
		workers.Add(1)
		go func(request Request) {
			defer workers.Done()
			defer func() {
				operationsMu.Lock()
				delete(operations, request.ID)
				operationsMu.Unlock()
				cancel(nil)
			}()
			emit := func(event string, revision uint64, data any) error {
				encoded, err := json.Marshal(data)
				if err != nil {
					return fmt.Errorf("encode RPC event: %w", err)
				}
				return enqueue(Response{Version: ProtocolVersion, Type: "event", ID: request.ID,
					Sequence: sequence.Add(1), Revision: revision, Event: event, Data: encoded})
			}
			result, err := session.Handler.Handle(operationContext, Call{
				ID: request.ID, Method: request.Method, Params: request.Params,
			}, emit)
			response := Response{Version: ProtocolVersion, Type: "response", ID: request.ID, Result: result}
			if err != nil {
				if errors.Is(err, context.Canceled) || errors.Is(context.Cause(operationContext), contextCanceled) {
					err = contextCanceled
				}
				response.Result = nil
				response.Error = asFault(err)
			}
			_ = enqueue(response)
		}(request)
	}
	stop()
	operationsMu.Lock()
	for _, cancel := range operations {
		cancel(context.Canceled)
	}
	operationsMu.Unlock()
	workers.Wait()
	close(outgoing)
	writerErr := <-writerDone
	if readErr != nil {
		return readErr
	}
	return writerErr
}
