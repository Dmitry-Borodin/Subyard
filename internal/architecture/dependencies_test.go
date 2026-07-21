package architecture

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestProductionDoesNotImportTestkit(t *testing.T) {
	root := filepath.Clean(filepath.Join("..", ".."))
	walkGoFiles(t, root, func(path string, file *ast.File) {
		if strings.Contains(path, string(filepath.Separator)+"testkit"+string(filepath.Separator)) {
			return
		}
		for _, imported := range imports(file) {
			if strings.HasSuffix(imported, "/internal/testkit") {
				t.Errorf("production file imports testkit: %s", path)
			}
		}
	})
}

func TestDomainAndPortsHaveNoPlatformDependencies(t *testing.T) {
	root := filepath.Clean(filepath.Join("..", ".."))
	for _, packageName := range []string{"domain", "ports", "application", "credential"} {
		directory := filepath.Join(root, "internal", packageName)
		if _, err := os.Stat(directory); err != nil {
			continue
		}
		walkGoFiles(t, directory, func(path string, file *ast.File) {
			for _, imported := range imports(file) {
				if strings.Contains(imported, "lxc/incus") || imported == "os/exec" ||
					strings.Contains(imported, "/internal/adapters/") ||
					strings.Contains(imported, "/internal/testkit") {
					t.Errorf("platform dependency %q in %s", imported, path)
				}
			}
		})
	}
}

func walkGoFiles(t *testing.T, root string, visit func(string, *ast.File)) {
	t.Helper()
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
		if err != nil {
			return err
		}
		visit(path, file)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func imports(file *ast.File) []string {
	result := make([]string, 0, len(file.Imports))
	for _, specification := range file.Imports {
		path, err := strconv.Unquote(specification.Path.Value)
		if err == nil {
			result = append(result, path)
		}
	}
	return result
}
