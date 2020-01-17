package target

import (
	"bytes"
	"encoding/json"
	"sort"
	"strings"

	"github.com/appbricks/cloud-builder/terraform"
	"github.com/mevansam/goutils/logger"
	"github.com/mevansam/goutils/utils"
)

type TargetSet struct {
	ctx context

	targets map[string]*Target
}

// interface definition of global config context
// specific to TargetSet. declared here to simplify
// mocking and avoid cyclical dependencies.
type context interface {
	NewTarget(
		recipeName,
		recipeIaas string,
	) (*Target, error)
}

func NewTargetSet(ctx context) *TargetSet {

	return &TargetSet{
		ctx:     ctx,
		targets: make(map[string]*Target),
	}
}

func (ts *TargetSet) Lookup(
	recipeName, iaasName string,
	keyValues ...string,
) []*Target {

	var (
		key strings.Builder
	)

	key.WriteString(recipeName)
	key.Write([]byte{'/'})
	key.WriteString(iaasName)
	key.Write([]byte{'/'})
	key.WriteString(strings.Join(keyValues, "/"))
	keyPath := key.String()

	targets := make([]*Target, 0, len(ts.targets))
	l := 0

	for _, t := range ts.targets {

		if strings.HasPrefix(t.Key(), keyPath) {
			// add targets to array
			// sorting it along the way
			i := sort.Search(l, func(j int) bool {
				return targets[j].DeploymentName() > t.DeploymentName()
			})
			targets = append(targets, nil)
			if targets[i] != nil {
				copy(targets[i+1:], targets[i:])
			}
			targets[i] = t
			l++
		}
	}
	return targets
}

func (ts *TargetSet) GetTargets() []*Target {

	targets := make([]*Target, len(ts.targets))
	i := 0
	for _, t := range ts.targets {
		targets[i] = t
		i++
	}
	return targets
}

func (ts *TargetSet) GetTarget(name string) *Target {
	logger.TraceMessage(
		"Retrieving target with name '%s' from: %# v",
		name, ts.targets)

	return ts.targets[name]
}

func (ts *TargetSet) SaveTarget(key string, target *Target) {
	logger.TraceMessage("Saving target: %# v", target)

	// delete target with given key before
	// saving in the target map, as the key of
	// the new/updated target may have changed
	delete(ts.targets, key)
	ts.targets[target.Key()] = target
}

func (ts *TargetSet) DeleteTarget(key string) {
	logger.TraceMessage("Saving target with key. %s", key)
	delete(ts.targets, key)
}

// interface: encoding/json/Unmarshaler

func (ts *TargetSet) UnmarshalJSON(b []byte) error {

	var (
		err error

		target *Target
	)

	// temporary target data structure used
	// when parsing serialized targets
	parsedTarget := struct {
		RecipeName string `json:"recipeName"`
		RecipeIaas string `json:"recipeIaas"`

		Recipe   json.RawMessage `json:"recipe"`
		Provider json.RawMessage `json:"provider"`
		Backend  json.RawMessage `json:"backend"`

		Output *map[string]terraform.Output `json:"output,omitempty"`

		CookbookTimestamp string `json:"cookbook_timestamp"`
	}{}

	decoder := json.NewDecoder(bytes.NewReader(b))

	// read array open bracket
	if _, err = utils.ReadJSONDelimiter(decoder, utils.JsonArrayStartDelim); err != nil {
		return err
	}

	for decoder.More() {
		if err = decoder.Decode(&parsedTarget); err != nil {
			return err
		}

		if target, err = ts.ctx.NewTarget(
			parsedTarget.RecipeName,
			parsedTarget.RecipeIaas,
		); err != nil {
			return err
		}
		if err = json.Unmarshal(parsedTarget.Recipe, target.Recipe); err != nil {
			return err
		}
		if err = json.Unmarshal(parsedTarget.Provider, target.Provider); err != nil {
			return err
		}
		if err = json.Unmarshal(parsedTarget.Backend, target.Backend); err != nil {
			return err
		}
		target.Output = parsedTarget.Output
		target.CookbookTimestamp = parsedTarget.CookbookTimestamp

		ts.targets[target.Key()] = target
	}

	// read array close bracket
	if _, err = utils.ReadJSONDelimiter(decoder, utils.JsonArrayEndDelim); err != nil {
		return err
	}

	return nil
}

// interface: encoding/json/Marshaler

func (ts *TargetSet) MarshalJSON() ([]byte, error) {

	var (
		err   error
		out   bytes.Buffer
		first bool
	)
	encoder := json.NewEncoder(&out)
	first = true

	if _, err = out.WriteRune('['); err != nil {
		return out.Bytes(), err
	}

	for _, target := range ts.targets {
		if first {
			first = false
		} else {
			out.WriteRune(',')
		}

		if err = encoder.Encode(target); err != nil {
			return out.Bytes(), err
		}
	}

	if _, err = out.WriteRune(']'); err != nil {
		return out.Bytes(), err
	}

	return out.Bytes(), nil
}
